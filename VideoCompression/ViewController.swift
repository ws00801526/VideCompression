//
//  ViewController.swift
//  VideoCompression
//
//  Created by XMFraker on 2021/3/2.
//

import UIKit
import Photos
import PhotosUI

class ViewController: UIViewController {

    
    var cancellable: VideoCompression.Cancellable?
    @IBOutlet weak var cacheSegmented: UISegmentedControl!
    @IBOutlet weak var preferredSegmented: UISegmentedControl!

    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    @IBAction func album() {
        var config = PHPickerConfiguration.init()
        config.filter = PHPickerFilter.videos
        let picker = PHPickerViewController.init(configuration: config)
        picker.delegate = self
        show(picker, sender: nil)
    }
    
    @IBAction func stop() {
        if let cancellable = cancellable { cancellable.cancell() }
        self.cancellable = nil
    }
}

extension ViewController {
    
    var preferred: VideoCompression.Preferred {
        switch preferredSegmented.selectedSegmentIndex {
        case 0: return .i1080p
        case 1: return .i720p
        case 2: return .i576
        case 3: return .i480
        case 4: return .i360
        case 5: return .custom((resulution: .init(width: 600, height: 600), videoBitrate: 600 * 1024, frameRate: 24, audioBitrate: 64 * 1024))
        default: return .i480
        }
    }
    
    var cache: VideoCompression.Cache {
        switch cacheSegmented.selectedSegmentIndex {
        case 0: return .none
        case 1: return .useCache
        case 2: return .forceDelete
        default: return .none
        }
    }
}

extension ViewController: VideoCompressionProcessor {
    func process(buffer: CMSampleBuffer, of type: AVMediaType) -> CMSampleBuffer {
        debugPrint("will process buffer")
        return buffer
    }
}

extension ViewController: PHPickerViewControllerDelegate {
    
    func compress(of fileURL: URL?) {
        guard let compressURL = fileURL else { return }
        let destinationURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("temp.mp4")
        debugPrint("before : \(compressURL)  \nafter: \(destinationURL)")
        debugPrint("before file data size: \(((try? Data(contentsOf: compressURL))?.count ?? 0) / 1024 / 1024)MB")
        try? FileManager.default.removeItem(at: destinationURL)
        let start = Date()
        let cache = self.cache
        let preferred = self.preferred
        cancellable = VideoCompression.compressh264Video(from: compressURL, cache: cache, preferred: preferred) { progress in
            debugPrint("here is compress progress \(progress.fractionCompleted)")
            if progress.isFinished { debugPrint("here is compress finished") }
        } completion: { (url, error) in
            if let e = error { debugPrint("here is compress failed \(e.localizedDescription)") }
            else if let output = url {
                debugPrint("here is compress \(output)")
                debugPrint("compress cost time: \(Date().timeIntervalSince(start))s")
                debugPrint("compress file data size: \(((try? Data(contentsOf: output))?.count ?? 0) / 1024 / 1024)MB")
            }
        }
    }
    
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        
        picker.dismiss(animated: true, completion: nil)
        guard let result = results.first else { return }
        result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] (url, error) in
            if let url = url { self?.compress(of: url) }
        }
    }
}

