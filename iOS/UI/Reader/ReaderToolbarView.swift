//
//  ReaderToolbarView.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/15/22.
//

import Combine
import UIKit

class ReaderToolbarView: UIView {
    var currentPageValue: Int? {
        didSet {
            if oldValue != currentPageValue {
                let feedbackGenerator = UISelectionFeedbackGenerator()
                feedbackGenerator.selectionChanged()
            }
        }
    }
    var currentPage: Int? {
        didSet { updatePageLabels() }
    }
    var totalPages: Int? {
        didSet { updatePageLabels() }
    }

    let sliderView = ReaderSliderView()
    private let incognitoModeLabel = UILabel()
    private let currentPageLabel = UILabel()
    private let pagesLeftLabel = UILabel()
    private let autoReadingStack = UIStackView()
    private let autoReadingSpeedLabel = UILabel()
    private let autoReadingDecreaseButton = UIButton(type: .system)
    private let autoReadingIncreaseButton = UIButton(type: .system)
    private let autoReadingStopButton = UIButton(type: .system)

    var onAutoReadingSpeedChange: ((Double) -> Void)?
    var onAutoReadingStop: (() -> Void)?
    private(set) var autoReadingSpeed = 1.0
    private var autoReadingActive = false

    private var cancellables: [AnyCancellable] = []

    init() {
        super.init(frame: .zero)
        configure()
        constrain()
        observe()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure() {
        incognitoModeLabel.font = .systemFont(ofSize: 10)
        incognitoModeLabel.textColor = .secondaryLabel
        incognitoModeLabel.textAlignment = .left
        incognitoModeLabel.isHidden = !UserDefaults.standard.bool(forKey: "General.incognitoMode")
        addSubview(incognitoModeLabel)

        currentPageLabel.font = .systemFont(ofSize: 10)
        currentPageLabel.textAlignment = .center
        currentPageLabel.sizeToFit()
        addSubview(currentPageLabel)

        pagesLeftLabel.font = .systemFont(ofSize: 10)
        pagesLeftLabel.textColor = .secondaryLabel
        pagesLeftLabel.textAlignment = .right
        addSubview(pagesLeftLabel)

        sliderView.semanticContentAttribute = .playback // for rtl languages
        addSubview(sliderView)

        autoReadingSpeedLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        autoReadingSpeedLabel.textAlignment = .center
        autoReadingSpeedLabel.widthAnchor.constraint(equalToConstant: 56).isActive = true

        configureAutoReadingButton(autoReadingDecreaseButton, systemName: "minus", action: #selector(decreaseAutoReadingSpeed))
        configureAutoReadingButton(autoReadingIncreaseButton, systemName: "plus", action: #selector(increaseAutoReadingSpeed))
        configureAutoReadingButton(autoReadingStopButton, systemName: "stop.fill", action: #selector(stopAutoReading))
        autoReadingStopButton.accessibilityLabel = textReaderLocalized("AUTO_READING_STOP", fallback: "Stop Auto Reading")

        autoReadingStack.axis = .horizontal
        autoReadingStack.alignment = .center
        autoReadingStack.distribution = .equalCentering
        autoReadingStack.addArrangedSubview(autoReadingDecreaseButton)
        autoReadingStack.addArrangedSubview(autoReadingSpeedLabel)
        autoReadingStack.addArrangedSubview(autoReadingIncreaseButton)
        autoReadingStack.addArrangedSubview(autoReadingStopButton)
        autoReadingStack.isHidden = true
        addSubview(autoReadingStack)
    }

    func constrain() {
        incognitoModeLabel.translatesAutoresizingMaskIntoConstraints = false
        currentPageLabel.translatesAutoresizingMaskIntoConstraints = false
        pagesLeftLabel.translatesAutoresizingMaskIntoConstraints = false
        sliderView.translatesAutoresizingMaskIntoConstraints = false
        autoReadingStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            incognitoModeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            incognitoModeLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            currentPageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            currentPageLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            pagesLeftLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            pagesLeftLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            sliderView.heightAnchor.constraint(equalToConstant: 12),
            sliderView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            sliderView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sliderView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            autoReadingStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            autoReadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            autoReadingStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32)
        ])
    }

    private func configureAutoReadingButton(_ button: UIButton, systemName: String, action: Selector) {
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    func setAutoReading(active: Bool, speed: Double) {
        autoReadingActive = active
        autoReadingSpeed = min(4, max(0.5, speed))
        autoReadingSpeedLabel.text = String(format: "%.2f×", autoReadingSpeed)
        autoReadingDecreaseButton.isEnabled = autoReadingSpeed > 0.5
        autoReadingIncreaseButton.isEnabled = autoReadingSpeed < 4
        autoReadingStack.isHidden = !active
        sliderView.isHidden = active
        incognitoModeLabel.isHidden = active || !UserDefaults.standard.bool(forKey: "General.incognitoMode")
        currentPageLabel.isHidden = active
        pagesLeftLabel.isHidden = active
    }

    @objc private func decreaseAutoReadingSpeed() {
        changeAutoReadingSpeed(by: -0.25)
    }

    @objc private func increaseAutoReadingSpeed() {
        changeAutoReadingSpeed(by: 0.25)
    }

    private func changeAutoReadingSpeed(by amount: Double) {
        let speed = min(4, max(0.5, ((autoReadingSpeed + amount) * 4).rounded() / 4))
        setAutoReading(active: true, speed: speed)
        onAutoReadingSpeedChange?(speed)
    }

    @objc private func stopAutoReading() {
        onAutoReadingStop?()
    }

    func observe() {
        NotificationCenter.default.publisher(for: .incognitoMode)
            .sink { [weak self] _ in
                guard let self else { return }
                self.incognitoModeLabel.isHidden = self.autoReadingActive
                    || !UserDefaults.standard.bool(forKey: "General.incognitoMode")
            }
            .store(in: &cancellables)
    }

    // allow slider thumb to be touched outside bounds
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !autoReadingStack.isHidden, autoReadingStack.bounds.contains(convert(point, to: autoReadingStack)) {
            return super.hitTest(point, with: event)
        }
        for subview in subviews where subview is ReaderSliderView {
            if subview.subviews.contains(where: { $0.bounds.contains(convert(point, to: $0)) }) {
                return subview
            }
        }
        return super.hitTest(point, with: event)
    }

    func displayPage(_ page: Int) {
        guard let totalPages = totalPages else {
            return
        }
        var page = page
        if page > totalPages {
            page = totalPages
        } else if page < 1 {
            page = 1
        }
        currentPageLabel.text = String(format: NSLocalizedString("%i_OF_%i", comment: ""), page, totalPages)
        currentPageValue = page
    }

    func updatePageLabels() {
        guard var currentPage = currentPage, let totalPages = totalPages else {
            currentPageLabel.text = nil
            pagesLeftLabel.text = nil
            return
        }

        if currentPage > totalPages {
            currentPage = totalPages
        } else if currentPage < 1 {
            currentPage = 1
        }
        let pagesLeft = totalPages - currentPage
        currentPageLabel.text = String(format: NSLocalizedString("%i_OF_%i", comment: ""), currentPage, totalPages)
        if pagesLeft < 1 {
            pagesLeftLabel.text = nil
        } else {
            pagesLeftLabel.text = pagesLeft == 1
                ? NSLocalizedString("ONE_PAGE_LEFT", comment: "")
                : String(format: NSLocalizedString("%i_PAGES_LEFT", comment: ""), pagesLeft)
        }
        incognitoModeLabel.text = NSLocalizedString("INCOGNITO_MODE")
    }

    func updateSliderPosition() {
        guard let currentPage = currentPage, let totalPages = totalPages else { return }
        sliderView.move(toValue: CGFloat(currentPage - 1) / max(CGFloat(totalPages - 1), 1))
    }
}
