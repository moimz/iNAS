import AMSMB2
import AVFoundation
import CoreGraphics
import FFmpeg
import Foundation

/// FFmpeg 로 NAS 의 동영상에서 한 장면을 뽑는다 (AVFoundation 이 못 여는 mkv·avi·wmv, 영상 정보가 뒤쪽에 있는 mp4 등).
/// 파일을 받아 두지 않고, FFmpeg 가 읽자는 위치만 SMB 로 그때그때 읽어 넘긴다 (사용자 입출력 콜백).
enum VideoFrame {
    /// 한 장면을 뽑는 동안 NAS 에서 읽을 수 있는 최대 양 (넘으면 포기)
    static let readLimit: Int64 = 48 << 20

    /// 장면, 그리고 실패했을 때 다시 해 볼 만한지 (SMB 읽기 실패 = 다시, 형식·디코딩 실패 = 다시 해도 같음)
    static func ffmpeg(manager: SMB2Manager, path: String, size: Int64, maxPixels: Int) async -> (image: CGImage?, retryable: Bool, reason: String?) {
        await withCheckedContinuation { continuation in
            // FFmpeg 는 읽기를 기다리며 스레드를 붙잡으니 Swift 동시성 스레드가 아닌 따로 큐에서 돌린다
            DispatchQueue.global(qos: .utility).async {
                let reader = SMBReader(manager: manager, path: path, size: size)
                let image = Decoder.frame(reader: reader, maxPixels: maxPixels)
                continuation.resume(returning: (image, reader.failure?.contains("SMB") == true, reader.failure))
            }
        }
    }
}

extension VideoFrame {
    /// 거의 검은 화면인지 (16x16 으로 줄여 밝기 평균)
    static func isDark(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        guard drawn else { return false }
        var total = 0
        for i in stride(from: 0, to: pixels.count, by: 4) { total += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) }
        return total / (16 * 16 * 3) < 24
    }
}

/// AVFoundation 이 mp4 에서 읽자는 위치를 SMB 로 읽어 넘긴다 (사용자 정의 URL + 리소스 로더).
/// 영상 정보 풀기·디코딩은 AVFoundation 이 하니 확장 메모리(약 20MB)를 거의 안 쓴다. 파일을 받아 두지 않는다.
final class SMBAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let manager: SMB2Manager
    let path: String
    let size: Int64
    let ext: String
    /// 한 장면 뽑는 동안 읽을 수 있는 최대 양
    static let readLimit: Int64 = 64 << 20
    private static let chunk: Int64 = 256 << 10
    private let queue = DispatchQueue(label: "smb-asset-loader")
    private let lock = NSLock()
    private var _totalRead: Int64 = 0
    private var cancelled = false
    private var generator: AVAssetImageGenerator?

    var totalRead: Int64 { lock.withLock { _totalRead } }

    init(manager: SMB2Manager, path: String, size: Int64, ext: String) {
        self.manager = manager
        self.path = path
        self.size = size
        self.ext = ext
    }

    func cancel() {
        lock.withLock { cancelled = true }
        generator?.cancelAllCGImageGeneration()
    }

    /// 전체의 10% (최대 2분) 근처 키프레임, 거의 검으면 1분씩 뒤로 두 번 더
    func frame(maxPixels: Int) async throws -> CGImage {
        let url = URL(string: "inas-smb://thumbnail/video.\(ext)")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        self.generator = generator
        let base = duration.isFinite && duration > 0 ? min(duration / 10, 120) : 1
        var fallback: CGImage?
        for attempt in 0..<3 {
            let seconds = base + Double(attempt) * 60
            if attempt > 0, duration.isFinite, seconds >= duration { break }
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            if !VideoFrame.isDark(image) { return image }
            fallback = fallback ?? image
        }
        if let fallback { return fallback }
        throw CocoaError(.fileReadCorruptFile)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = (ext == "mov" ? UTType.quickTimeMovie : UTType.mpeg4Movie).identifier
            info.contentLength = size
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let start = dataRequest.requestedOffset
        let end = dataRequest.requestsAllDataToEndOfResource ? size : min(size, start + Int64(dataRequest.requestedLength))
        Task { [self] in
            var offset = max(start, dataRequest.currentOffset)
            while offset < end {
                if loadingRequest.isCancelled || lock.withLock({ cancelled }) { return }
                guard totalRead < Self.readLimit else {
                    queue.async { loadingRequest.finishLoading(with: CocoaError(.fileReadTooLarge)) }
                    return
                }
                let upper = min(end, offset + Self.chunk)
                guard let data = try? await manager.contents(atPath: path, range: UInt64(offset)..<UInt64(upper), progress: nil),
                      !data.isEmpty else {
                    queue.async { loadingRequest.finishLoading(with: CocoaError(.fileReadUnknown)) }
                    return
                }
                lock.withLock { _totalRead += Int64(data.count) }
                queue.sync { dataRequest.respond(with: data) }
                offset += Int64(data.count)
            }
            queue.async { loadingRequest.finishLoading() }
        }
        return true
    }
}

/// FFmpeg 가 부르는 읽기·찾기를 SMB 범위 읽기로 바꾼다. 512KB 단위로 읽어 두고 그 안이면 다시 묻지 않는다.
final class SMBReader {
    let manager: SMB2Manager
    let path: String
    let size: Int64
    var position: Int64 = 0
    var totalRead: Int64 = 0
    /// 실패 이유 (로그용)
    var failure: String?
    private var block = Data()
    private var blockStart: Int64 = -1
    private static let blockSize: Int64 = 512 << 10

    init(manager: SMB2Manager, path: String, size: Int64) {
        self.manager = manager
        self.path = path
        self.size = size
    }

    /// 지금 위치부터 최대 count 바이트를 buffer 에 채운다. 끝이면 0, 실패면 -1.
    func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard position < size else { return 0 }
        if blockStart < 0 || position < blockStart || position >= blockStart + Int64(block.count) {
            guard totalRead < VideoFrame.readLimit else { failure = "읽기 한도 넘음"; return -1 }
            let start = position
            let end = min(size, start + Self.blockSize)
            guard let data = fetch(start..<end), !data.isEmpty else { failure = failure ?? "SMB 읽기 실패 @\(start)"; return -1 }
            block = data
            blockStart = start
            totalRead += Int64(data.count)
        }
        let offset = Int(position - blockStart)
        let length = min(count, block.count - offset)
        block.withUnsafeBytes { raw in
            buffer.update(from: raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + offset, count: length)
        }
        position += Int64(length)
        return length
    }

    private func fetch(_ range: Range<Int64>) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Data?
        manager.contents(atPath: path, range: UInt64(range.lowerBound)..<UInt64(range.upperBound), progress: nil) { outcome in
            result = try? outcome.get()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 20) == .timedOut { failure = "SMB 읽기 20초 넘음"; return nil }
        return result
    }
}

private enum Decoder {
    /// AVERROR_EOF = -MKTAG('E','O','F',' ')
    static let eof: Int32 = -0x2046_4F45
    static let again: Int32 = -EAGAIN

    static func frame(reader: SMBReader, maxPixels: Int) -> CGImage? {
        let opaque = Unmanaged.passUnretained(reader).toOpaque()
        let bufferSize: Int32 = 64 << 10
        guard let buffer = av_malloc(Int(bufferSize))?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let read: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32 = { opaque, buf, size in
            guard let opaque, let buf else { return Decoder.eof }
            let reader = Unmanaged<SMBReader>.fromOpaque(opaque).takeUnretainedValue()
            let count = reader.read(into: buf, count: Int(size))
            return count > 0 ? Int32(count) : Decoder.eof
        }
        let seek: @convention(c) (UnsafeMutableRawPointer?, Int64, Int32) -> Int64 = { opaque, offset, whence in
            guard let opaque else { return -1 }
            let reader = Unmanaged<SMBReader>.fromOpaque(opaque).takeUnretainedValue()
            switch whence & ~AVSEEK_FORCE {
            case AVSEEK_SIZE: return reader.size
            case SEEK_SET: reader.position = offset
            case SEEK_CUR: reader.position += offset
            case SEEK_END: reader.position = reader.size + offset
            default: return -1
            }
            return reader.position
        }
        guard var io = avio_alloc_context(buffer, bufferSize, 0, opaque, read, nil, seek) else {
            av_free(buffer)
            return nil
        }
        defer {
            av_freep(&io.pointee.buffer)
            var ioPointer: UnsafeMutablePointer<AVIOContext>? = io
            avio_context_free(&ioPointer)
        }

        var format = avformat_alloc_context()
        format?.pointee.pb = io
        format?.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        format?.pointee.probesize = 4 << 20
        format?.pointee.max_analyze_duration = 2 * Int64(AV_TIME_BASE)
        guard avformat_open_input(&format, nil, nil, nil) == 0, let context = format else { reader.failure = reader.failure ?? "형식 열기 실패"; return nil }
        defer { avformat_close_input(&format) }
        let streamInfo = avformat_find_stream_info(context, nil)
        guard streamInfo >= 0 else { reader.failure = reader.failure ?? "스트림 정보 실패"; return nil }

        var codec: UnsafePointer<AVCodec>?
        let index = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0)
        guard index >= 0, let codec, let stream = context.pointee.streams[Int(index)] else { reader.failure = reader.failure ?? "영상 스트림/디코더 없음"; return nil }
        var decoder = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&decoder) }
        guard let decoder, avcodec_parameters_to_context(decoder, stream.pointee.codecpar) >= 0 else { return nil }
        // 확장은 메모리가 빠듯하다: 스레드 하나(스레드마다 프레임 버퍼를 따로 잡음), 썸네일이니 화질 보정 생략
        decoder.pointee.thread_count = 1
        decoder.pointee.flags2 |= AV_CODEC_FLAG2_FAST
        decoder.pointee.skip_loop_filter = AVDISCARD_ALL
        guard avcodec_open2(decoder, codec, nil) >= 0 else { reader.failure = "디코더 열기 실패"; return nil }
        let codecName = String(cString: codec.pointee.name)
        reader.failure = "\(codecName) \(decoder.pointee.width)x\(decoder.pointee.height)"

        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        defer {
            av_packet_free(&packet)
            av_frame_free(&frame)
        }
        guard let packet, let frame else { return nil }

        // 앞쪽 검은 화면·제작사 로고를 피해 전체의 10% (최대 2분) 근처 키프레임. 장면이 거의 검으면 1분씩 뒤로 두 번 더.
        let duration = context.pointee.duration
        let base = duration > 0 ? min(duration / 10, 120 * Int64(AV_TIME_BASE)) : 0
        var fallback: CGImage?
        for attempt in 0..<3 {
            let target = base + Int64(attempt) * 60 * Int64(AV_TIME_BASE)
            if duration > 0, target < duration {
                avformat_seek_file(context, -1, Int64.min, target, target, 0)
                avcodec_flush_buffers(decoder)
            } else if attempt > 0 {
                break
            }
            guard let image = decode(context: context, decoder: decoder, stream: index, packet: packet, frame: frame,
                                     maxPixels: maxPixels, reader: reader) else { break }
            if !isDark(image) { return image }
            fallback = fallback ?? image
        }
        return fallback
    }

    /// 지금 위치에서 처음 나오는 영상 프레임 하나
    static func decode(context: UnsafeMutablePointer<AVFormatContext>, decoder: UnsafeMutablePointer<AVCodecContext>, stream index: Int32,
                       packet: UnsafeMutablePointer<AVPacket>, frame: UnsafeMutablePointer<AVFrame>,
                       maxPixels: Int, reader: SMBReader) -> CGImage? {
        var packets = 0
        while packets < 600, av_read_frame(context, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == index else { continue }
            packets += 1
            guard avcodec_send_packet(decoder, packet) >= 0 else { continue }
            if avcodec_receive_frame(decoder, frame) == 0 {
                return image(from: frame, maxPixels: maxPixels)
            }
        }
        // 남은 프레임 꺼내기
        avcodec_send_packet(decoder, nil)
        if avcodec_receive_frame(decoder, frame) == 0 { return image(from: frame, maxPixels: maxPixels) }
        reader.failure = (reader.failure ?? "") + " 프레임 못 얻음(패킷 \(packets))"
        return nil
    }

    static func isDark(_ image: CGImage) -> Bool { VideoFrame.isDark(image) }

    /// 디코딩한 프레임을 긴 변 maxPixels 이하 RGBA CGImage 로
    static func image(from frame: UnsafeMutablePointer<AVFrame>, maxPixels: Int) -> CGImage? {
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }
        // 화면 비율(SAR) 반영
        let sar = frame.pointee.sample_aspect_ratio
        let displayWidth = sar.num > 0 && sar.den > 0 ? Double(width) * Double(sar.num) / Double(sar.den) : Double(width)
        let scale = min(1, Double(maxPixels) / max(displayWidth, Double(height)))
        let outWidth = max(1, Int(displayWidth * scale)), outHeight = max(1, Int(Double(height) * scale))
        guard let sws = sws_getContext(Int32(width), Int32(height), AVPixelFormat(frame.pointee.format),
                                       Int32(outWidth), Int32(outHeight), AV_PIX_FMT_RGBA,
                                       Int32(SWS_BILINEAR.rawValue), nil, nil, nil) else { return nil }
        defer { sws_freeContext(sws) }
        let bytesPerRow = outWidth * 4
        var pixels = Data(count: bytesPerRow * outHeight)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            var destination: [UnsafeMutablePointer<UInt8>?] = [raw.baseAddress?.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
            var strides: [Int32] = [Int32(bytesPerRow), 0, 0, 0]
            let source = withUnsafePointer(to: &frame.pointee.data) {
                $0.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { Array(UnsafeBufferPointer(start: $0, count: 8)) }
            }
            let sourceStrides = withUnsafePointer(to: &frame.pointee.linesize) {
                $0.withMemoryRebound(to: Int32.self, capacity: 8) { Array(UnsafeBufferPointer(start: $0, count: 8)) }
            }
            return sws_scale(sws, source, sourceStrides, 0, Int32(height), &destination, &strides) > 0
        }
        guard ok, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
