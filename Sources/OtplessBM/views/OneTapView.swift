//
//  OneTapBottomSheetViewController.swift
//  OtplessSDK
//
//  Created by Sparsh on 13/02/25.
//


import UIKit


internal enum OneTapTheme {
    // Surfaces
    static let sheetBackground = UIColor { tc in
        tc.userInterfaceStyle == .dark ? UIColor(red: 0.125, green: 0.125, blue: 0.125, alpha: 1.0) : UIColor.white
    }
    
    static let cardBackground = UIColor { tc in
        tc.userInterfaceStyle == .dark ? UIColor(red: 0.196, green: 0.196, blue: 0.196, alpha: 1.0) : UIColor(red: 0.946, green: 0.946, blue: 0.946, alpha: 1.0)
    }
    
    static let titleText = UIColor { tc in
        tc.userInterfaceStyle == .dark ? UIColor.white : UIColor.black
    }
    
    static let subtitleText: UIColor = UIColor(red: 0.502, green: 0.514, blue: 0.553, alpha: 1.0)
    
    static let imageBackground = UIColor { tc in
        tc.userInterfaceStyle == .dark ? UIColor(red: 0.257, green: 0.257, blue: 0.257, alpha: 1.0) : UIColor.white
    }
    
    static let border = UIColor { tc in
        tc.userInterfaceStyle == .dark ? UIColor(red: 0.427, green: 0.427, blue: 0.427, alpha: 1.0) : UIColor(red: 0.821, green: 0.821, blue: 0.821, alpha: 1.0)
    }
    
}

internal final class OneTapView: UIView {
    var items: [OnetapItemData]
    private let onItemSelected: (OnetapItemData) -> Void
    private let onDismiss: () -> Void
    
    private let titleLabel = UILabel()
    private let tableView = UITableView()
    
    var isLoadingInProgress: Bool = false
    
    private lazy var footerLabel: UILabel = {
        let lbl = UILabel()
        lbl.text = "Use Different Mobile Number"
        lbl.font = UIFont.systemFont(ofSize: 18, weight: .regular)
        lbl.textAlignment = .center
        lbl.isUserInteractionEnabled = true
        
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapFooter))
        lbl.addGestureRecognizer(tap)
        return lbl
    }()
    
    public init(items: [OnetapItemData], onItemSelected: @escaping (OnetapItemData) -> Void, onDismiss: @escaping () -> Void) {
        self.items = items
        self.onItemSelected = onItemSelected
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        
        setupView()
        applyTheme()
        setupConstraints()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc private func didTapFooter() {
        if isLoadingInProgress { return }
        onDismiss()
    }
    
    private func applyTheme() {
        backgroundColor = OneTapTheme.sheetBackground
        titleLabel.textColor = OneTapTheme.titleText
        footerLabel.textColor = OneTapTheme.subtitleText
    }
    
    private func setupView() {
        layer.cornerRadius = 24
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.masksToBounds = true
        
        // title style setup
        titleLabel.text = "Select your mobile to Signup/Login"
        titleLabel.font = UIFont(name: "Roboto-Medium", size: 16)
        titleLabel.textAlignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        // table setup
        tableView.register(OneTapCell.self, forCellReuseIdentifier: "OneTapCell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = OneTapTheme.sheetBackground
        tableView.allowsSelection = true
        tableView.isUserInteractionEnabled = true
        
        tableView.dataSource = self
        tableView.delegate = self
        
        tableView.isScrollEnabled = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 56, bottom: 0, right: 0)
        tableView.separatorStyle = .none
        
        // ✅ Add vertical breathing space like screenshot
        tableView.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
        
        // ✅ Footer view container (tableFooterView needs a frame height)
        let footerContainer = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 50))
        footerLabel.frame = footerContainer.bounds
        footerLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        footerContainer.addSubview(footerLabel)
        tableView.tableFooterView = footerContainer
        
        addSubview(titleLabel)
        addSubview(tableView)
    }
    
    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // title padding
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            
            // table under title padding
            tableView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ])
    }
}

extension OneTapView: UITableViewDataSource {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "OneTapCell", for: indexPath) as! OneTapCell
        cell.configure(with: items[indexPath.row])
        cell.selectionStyle = .none
        return cell
    }
}

extension OneTapView: UITableViewDelegate {
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isLoadingInProgress { return }
        isLoadingInProgress = true
        titleLabel.text = "Logging you in..."
        var index = 0
        while (index < items.count) {
            items[index].action = -1
            index += 1
        }
        items[indexPath.row].action = 1
        tableView.reloadData()
        onItemSelected(items[indexPath.row])
    }
    
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
    
    public func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return 50
    }
}

class OneTapCell: UITableViewCell {
    
    private let phoneLabel: UILabel = {
        let lbl = UILabel()
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.font = UIFont(name: "Roboto-Medium", size: 14)
        lbl.lineBreakMode = .byWordWrapping
        lbl.textColor = .black
        lbl.numberOfLines = 1
        return lbl
    }()
    
    private let cardView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.layer.cornerRadius = 14
        v.layer.borderColor = OneTapTheme.border.cgColor
        v.layer.borderWidth = 1
        v.layer.masksToBounds = true
        return v
    }()
    
    //region ===== progress in image view
    private let avatarView: LogoRingView = {
        let iv = LogoRingView()
        return iv
    }()
    
    //endregion
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupCell()
        applyTheme()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func applyTheme() {
        phoneLabel.textColor = OneTapTheme.titleText
        cardView.backgroundColor = OneTapTheme.cardBackground
        self.backgroundColor = OneTapTheme.sheetBackground
        self.contentView.backgroundColor = OneTapTheme.sheetBackground
    }
    
    private func setupCell() {
        selectionStyle = .none
        
        let stackView = UIStackView(arrangedSubviews: [avatarView, phoneLabel])
        stackView.axis = .horizontal
        stackView.spacing = 16
        stackView.alignment = .fill
        stackView.distribution = .fillProportionally
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)
        cardView.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            // ✅ Card margins (so it looks inset like screenshot)
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            
            avatarView.widthAnchor.constraint(equalToConstant: 40),
            avatarView.heightAnchor.constraint(equalToConstant: 40),
            avatarView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            avatarView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),
            
            stackView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            stackView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),
            stackView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),
        ])
    }
    
    func configure(with item: OnetapItemData) {
        phoneLabel.text = item.identity
        if let logo = item.logo, let url = URL(string: logo) {
            ImageUtils.shared.loadImage(to: avatarView.imageView, from: url)
        }
        switch item.action {
        case 0:
            cardView.alpha = 1.0
            avatarView.setLoading(false)
        case 1:
            cardView.alpha = 1.0
            avatarView.setLoading(true)
        default:
            cardView.alpha = 0.45
            avatarView.setLoading(false)
        }
        
    }
}

// MARK: Disable ripple effect on all cells on which user's finger lands an item while scrolling
extension OneTapCell {
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        selectionStyle = .none
    }
}

import UIKit

@available(iOS 15.0, *)
final internal class OneTapBottomSheetViewController: UIViewController {
    
    private let oneTapView: OneTapView
    private let maxHeightRatio: CGFloat = 0.6
    
    init(oneTapView: OneTapView) {
        self.oneTapView = oneTapView
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet // ✅ makes it a bottom sheet on iOS 15+
        if let sheet = sheetPresentationController {
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            if #available(iOS 16.0, *) {
                let lowId = UISheetPresentationController.Detent.Identifier("low")
                let calculatedHeight = 128 + (74 * oneTapView.items.count)
                let cgHeight = CGFloat(calculatedHeight)
                sheet.detents = [
                    .custom(identifier: lowId) { _ in cgHeight }, // pick a height you want
                    .medium(),
                    .large()
                ]
                sheet.selectedDetentIdentifier = lowId
            } else {
                sheet.detents = [.medium(), .large()]
                sheet.selectedDetentIdentifier = .medium
            }
        }
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = OneTapTheme.sheetBackground
        view.addSubview(oneTapView)
        oneTapView.translatesAutoresizingMaskIntoConstraints = false
        // ✅ Attach view to bottom inside the sheet container
        NSLayoutConstraint.activate([
            oneTapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            oneTapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            oneTapView.topAnchor.constraint(equalTo: view.topAnchor),
            oneTapView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}


internal final class LogoRingView: UIView {
    
    let imageView = UIImageView()
    let ringLayer = CAShapeLayer()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = OneTapTheme.imageBackground
        clipsToBounds = false
        
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        
        addSubview(imageView)
        
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.70),
            imageView.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.70),
        ])
        
        // ring layer
        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.strokeColor = UIColor.systemBlue.cgColor
        ringLayer.lineWidth = 2
        ringLayer.lineCap = .round
        
        // show only an ARC (not full circle) like screenshot
        ringLayer.strokeStart = 0.15
        ringLayer.strokeEnd = 0.35
        ringLayer.isHidden = true
        
        layer.addSublayer(ringLayer)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        // make view and image circular
        layer.cornerRadius = bounds.width / 2
        imageView.layer.cornerRadius = imageView.bounds.width / 2
        
        // ring path slightly outside image
        let inset: CGFloat = 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        ringLayer.frame = bounds
        ringLayer.path = UIBezierPath(ovalIn: rect).cgPath
    }
    
    func setLoading(_ loading: Bool) {
        if loading {
            ringLayer.isHidden = false
            startRotating()
        } else {
            stopRotating()
            ringLayer.isHidden = true
        }
    }
    
    private func startRotating() {
        if ringLayer.animation(forKey: "rotate") != nil { return }
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue = CGFloat.pi * 2
        anim.duration = 0.8
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        ringLayer.add(anim, forKey: "rotate")
    }
    
    private func stopRotating() {
        ringLayer.removeAnimation(forKey: "rotate")
    }
}



