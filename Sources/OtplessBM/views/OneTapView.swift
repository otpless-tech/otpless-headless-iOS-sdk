//
//  OneTapBottomSheetViewController.swift
//  OtplessSDK
//
//  Created by Sparsh on 13/02/25.
//


import UIKit

class OneTapView: UIView {
    private let titleText: String
    private let items: [OneTapIdentity]
    private let onItemSelected: (OneTapIdentity) -> Void
    private let onDismiss: () -> Void
    
    private let titleLabel = UILabel()
    private let tableView = UITableView()
    private let dividerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .lightGray
        return view
    }()
    
    init(title: String, items: [OneTapIdentity], onItemSelected: @escaping (OneTapIdentity) -> Void, onDismiss: @escaping () -> Void) {
        self.titleText = title
        self.items = items
        self.onItemSelected = onItemSelected
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        
        setupView()
        setupConstraints()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupView() {
        backgroundColor = .white
        layer.cornerRadius = 16
        layer.masksToBounds = true
        
        titleLabel.text = titleText
        titleLabel.font = UIFont.boldSystemFont(ofSize: 20)
        titleLabel.textAlignment = .center
        titleLabel.textColor = .black
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        tableView.register(OneTapCell.self, forCellReuseIdentifier: "OneTapCell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .white
        tableView.allowsSelection = true
        tableView.isUserInteractionEnabled = true
        
        tableView.dataSource = self
        tableView.delegate = self
        
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 56, bottom: 0, right: 0)
        tableView.separatorStyle = .none
        
        addSubview(titleLabel)
        addSubview(tableView)
        addSubview(dividerView)
    }
    
    private func setupConstraints() {
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            
            dividerView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 15),
            dividerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dividerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dividerView.heightAnchor.constraint(equalToConstant: 0.4),
            
            tableView.topAnchor.constraint(equalTo: dividerView.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

extension OneTapView: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "OneTapCell", for: indexPath) as! OneTapCell
        cell.configure(with: items[indexPath.row])
        cell.backgroundColor = .white
        cell.selectionStyle = .none
        return cell
    }
}

extension OneTapView: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.row == items.count - 1 {
            // Selected the last item `Use another account`
            onDismiss()
            return
        }
        let selectedItem = items[indexPath.row]
        onItemSelected(selectedItem)
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
    
    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return 50
    }
}

class OneTapCell: UITableViewCell {
    
    private let nameLabel = UILabel()
    private let identityLabel = UILabel()
    private let iconImageView = UIImageView()
    private let dividerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .lightGray
        return view
    }()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupCell()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupCell() {
        nameLabel.numberOfLines = 0
        identityLabel.numberOfLines = 0
        nameLabel.lineBreakMode = .byWordWrapping
        identityLabel.lineBreakMode = .byWordWrapping
        
        nameLabel.font = UIFont.systemFont(ofSize: 15)
        nameLabel.textColor = .black
        identityLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        identityLabel.textColor = .black
        
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        
        let stackView = UIStackView(arrangedSubviews: [nameLabel, identityLabel])
        stackView.axis = .vertical
        stackView.spacing = 4
        stackView.alignment = .fill
        stackView.distribution = .fillProportionally
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        contentView.addSubview(iconImageView)
        contentView.addSubview(stackView)
        contentView.addSubview(dividerView)
        
        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            iconImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 24),
            iconImageView.heightAnchor.constraint(equalToConstant: 24),
            
            stackView.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stackView.bottomAnchor.constraint(equalTo: dividerView.topAnchor, constant: -22),
            
            dividerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 0.4)
        ])
        
        iconImageView.setContentHuggingPriority(.required, for: .horizontal)
        iconImageView.setContentHuggingPriority(.required, for: .vertical)
    }
    
    func configure(with identity: OneTapIdentity) {
        nameLabel.text = identity.name
        identityLabel.text = identity.identity
        nameLabel.isHidden = identity.name?.isEmpty ?? true
        
        if isEmail(identity.identity) {
            iconImageView.image = UIImage(systemName: "envelope")
        } else if identity.identity.lowercased() == "use another account" {
            iconImageView.image = UIImage(systemName: "plus")
        } else {
            iconImageView.image = UIImage(systemName: "phone")
        }
        
        iconImageView.tintColor = .black
    }
    
    private func isEmail(_ str: String) -> Bool {
        let emailRegex = "^[A-Za-z0-9+_.-]+@[A-Za-z0-9.-]+$"
        return NSPredicate(format: "SELF MATCHES %@", emailRegex).evaluate(with: str)
    }
}

// MARK: Disable ripple effect on all cells on which user's finger lands an item while scrolling
extension OneTapCell {
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        selectionStyle = .none
    }
}
