import FileProvider
import FileProviderUI
import UIKit

/// 파일 앱 안에 뜨는 인증 화면.
/// 확장이 NAS 로그인에 실패해 "인증 필요" 로 답하면 파일 앱이 이 화면을 띄운다 → iNAS 앱에서 아이디·비밀번호를 확인하라고 안내.
final class ActionViewController: FPUIActionExtensionViewController {
    private let messageLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let icon = UIImageView(image: UIImage(systemName: "person.crop.circle.badge.exclamationmark"))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.text = "NAS 에 로그인하지 못했습니다.\niNAS 앱에서 아이디와 비밀번호를 확인하세요."
        let closeButton = UIButton(type: .system)
        closeButton.setTitle("닫기", for: .normal)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [icon, messageLabel, closeButton])
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
    }

    override func prepare(forAction actionIdentifier: String, itemIdentifiers: [NSFileProviderItemIdentifier]) {
        close()
    }

    @objc private func close() {
        extensionContext.cancelRequest(withError: NSError(domain: FPUIErrorDomain,
                                                          code: Int(FPUIExtensionErrorCode.userCancelled.rawValue)))
    }
}
