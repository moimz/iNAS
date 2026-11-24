import FileProvider
import FileProviderUI
import LocalAuthentication
import UIKit

/// 파일 앱 안에 뜨는 인증 화면.
/// 확장이 "인증 필요" 로 답하면 파일 앱이 이 화면을 띄운다 — 잠금 폴더면 Face ID, 로그인 실패면 안내.
final class ActionViewController: FPUIActionExtensionViewController {
    private let messageLabel = UILabel()
    private let unlockButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        unlockButton.setTitle("Face ID 로 열기", for: .normal)
        unlockButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        unlockButton.addTarget(self, action: #selector(authenticate), for: .touchUpInside)
        closeButton.setTitle("닫기", for: .normal)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [icon, messageLabel, unlockButton, closeButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    override func prepare(forError error: Error) {
        loadViewIfNeeded()
        let reason = (error as NSError).userInfo[AuthReason.key] as? String
        if reason == AuthReason.loginFailed {
            messageLabel.text = "NAS 에 로그인하지 못했습니다.\niNAS 앱에서 아이디와 비밀번호를 확인하세요."
            unlockButton.isHidden = true
        } else {
            messageLabel.text = "잠금 폴더입니다.\nFace ID 로 확인하면 \(Int(Shared.lockInterval / 60))분 동안 열립니다."
            unlockButton.isHidden = false
            authenticate()
        }
    }

    override func prepare(forAction actionIdentifier: String, itemIdentifiers: [NSFileProviderItemIdentifier]) {
        close()
    }

    @objc private func authenticate() {
        let context = LAContext()
        // 아이폰을 생체 인증으로 방금 풀었으면 다시 묻지 않는다 (최대 5분, 동작은 기기에서 확인 필요)
        context.touchIDAuthenticationAllowableReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "잠금 폴더 열기") { success, error in
            DispatchQueue.main.async {
                if success {
                    if let id = self.extensionContext.domainIdentifier?.rawValue { LockState.unlock(id) }
                    self.extensionContext.completeRequest()
                } else {
                    self.messageLabel.text = "확인하지 못했습니다.\n\(error?.localizedDescription ?? "")"
                }
            }
        }
    }

    @objc private func close() {
        extensionContext.cancelRequest(withError: NSError(domain: FPUIErrorDomain,
                                                          code: Int(FPUIExtensionErrorCode.userCancelled.rawValue)))
    }
}
