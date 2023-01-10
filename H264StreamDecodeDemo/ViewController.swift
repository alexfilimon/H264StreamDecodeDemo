//
//  ViewController.swift
//  H264StreamDecodeDemo
//
//  Created by Prequel on 28.12.2022.
//

import UIKit
import Combine
import AVKit

class ViewController: UIViewController {

    private var streamToFileConverter: H264StreamToFileConverter?
    private var bag = Set<AnyCancellable>()
    private let convertButton = LoadingColoredButton(type: .custom)

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(convertButton)
        convertButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            convertButton.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            convertButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            convertButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            convertButton.heightAnchor.constraint(equalToConstant: 50)
        ])
        convertButton.addTarget(self, action: #selector(convertButtonPress), for: .touchUpInside)
        convertButton.configure(color: .systemGreen, title: "Convert", systemIconName: "arrow.left.arrow.right.square")
    }

    @objc
    private func convertButtonPress() {
        runConverting()
    }

    private func runConverting() {
        guard streamToFileConverter == nil else {
            return
        }
        convertButton.setLoading(true)
        let naluParser = try! H264NALUParserInputStream(
            fileURL: Bundle
                .main
                .url(
                    forResource: "stream",
                    withExtension: "h264"
                )!
        )
        let converter = try! H264StreamToFileConverter(
            inputFileConfig: .init(
                frameRate: 15,
                imageSize: .init(
                    width: 288*2,
                    height: 512*2
                )
            ),
            outputFileConfig: .init(
                folderURL: FileManager.default.temporaryDirectory
            ),
            naluParser: naluParser
        )
        converter
            .convert()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                switch response {
                case .failure(let error):
                    print("error: \(error)")
                case .finished:
                    ()
                }
                self?.convertButton.setLoading(false)
                self?.streamToFileConverter = nil
            } receiveValue: { [weak self] videoURL in
                self?.openVideoPlayer(url: videoURL)
            }
            .store(in: &bag)

        self.streamToFileConverter = converter
    }

    private func openVideoPlayer(url: URL) {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(playerItem: generatePlayerItem(url: url))
        present(controller, animated: true)
    }

    private func generatePlayerItem(url: URL) -> AVPlayerItem {
        let composition = AVMutableComposition()

        let videoComposition = AVMutableVideoComposition()

        let track1 = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )!
        let track2 = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )!

        let originalAsset = AVURLAsset(
            url: Bundle
                .main
                .url(
                    forResource: "original",
                    withExtension: "mov"
                )!,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let convertedAsset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )

        try! track1.insertTimeRange(
            .init(
                start: .zero,
                duration: .init(value: 180, timescale: 30)
            ),
            of: originalAsset.tracks(withMediaType: .video)[0],
            at: .zero
        )
        try! track2.insertTimeRange(
            .init(
                start: .zero,
                duration: .init(value: 180, timescale: 30)
            ),
            of: convertedAsset.tracks(withMediaType: .video)[0],
            at: .zero
        )

        let layer1instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track1)
        let originalAssetTrackSize = originalAsset.tracks(withMediaType: .video)[0].naturalSize
        let originalAssetPrefferedTransform = originalAsset.tracks(withMediaType: .video)[0].preferredTransform
        let originalAssetTrackSizeAfterPrefferedTransform = originalAssetTrackSize.applying(originalAssetPrefferedTransform)
        let scale = CGFloat(512*2) / originalAssetTrackSizeAfterPrefferedTransform.height
        layer1instruction.setTransform(.init(scaleX: scale, y: scale), at: .zero)

        let layer2instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track2)
        layer2instruction.setTransform(.init(translationX: 288*2, y: 0), at: .zero)

        let videoInstruction = AVMutableVideoCompositionInstruction()
        videoInstruction.timeRange = .init(
            start: .zero,
            duration: .init(value: 180, timescale: 30)
        )
        videoInstruction.layerInstructions = [
            layer1instruction,
            layer2instruction
        ]
        videoComposition.instructions = [videoInstruction]
        videoComposition.renderSize = .init(
            width: 288*4,
            height: 512*2
        )
        videoComposition.frameDuration = .init(value: 1, timescale: 30)

        let playerItem = AVPlayerItem(asset: composition)
        playerItem.videoComposition = videoComposition
        return playerItem
    }

}

class LoadingColoredButton: UIButton {

    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    func configure(
        color: UIColor,
        title: String?,
        systemIconName: String?
    ) {
        tintColor = .white

        addSubview(activityIndicator)
        adjustsImageWhenHighlighted = false
        adjustsImageWhenDisabled = false
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.color = .white
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        if let systemIconName {
            setImage(
                UIImage(
                    systemName: systemIconName,
                    withConfiguration: UIImage.SymbolConfiguration(
                        font: .systemFont(
                            ofSize: 18,
                            weight: .medium
                        )
                    )
                )?.withRenderingMode(.alwaysTemplate),
                for: .normal
            )
            imageEdgeInsets = .init(top: 0, left: 0, bottom: 0, right: 6)
            titleEdgeInsets = .init(top: 0, left: 0, bottom: 0, right: -6)

        }

        setTitle(title, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 18, weight: .medium).rounded
        setTitleColor(.white, for: .normal)
        setBackgroundImage(UIImage(color: color), for: .normal)
        setBackgroundImage(UIImage(color: color)?.imageWithAlpha(alpha: 0.7), for: .highlighted)
        setBackgroundImage(UIImage(color: color)?.imageWithAlpha(alpha: 0.5), for: .disabled)
        layer.cornerRadius = 10
        layer.masksToBounds = true

    }

    func setLoading(_ isLoading: Bool) {
        if isLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        titleLabel?.layer.opacity = isLoading ? 0 : 1
        imageView?.layer.transform = isLoading
            ? CATransform3DMakeScale(0, 0, 0)
            : CATransform3DIdentity
    }

}

extension UIFont {

    var rounded: UIFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }

}

extension UIImage {
    convenience init?(color: UIColor, size: CGSize = CGSize(width: 1, height: 1)) {
        let rect = CGRect(origin: .zero, size: size)
        UIGraphicsBeginImageContextWithOptions(rect.size, false, 0.0)
        color.setFill()
        UIRectFill(rect)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let cgImage = image?.cgImage else { return nil }
        self.init(cgImage: cgImage)
    }

    func imageWithAlpha(alpha: CGFloat) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(at: .zero, blendMode: .normal, alpha: alpha)
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage!
    }
}

