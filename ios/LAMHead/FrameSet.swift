import UIKit

/// 伺服器回傳的多角度影格，依 (pitch, yaw) 排成網格
final class FrameSet {
    let manifest: Manifest
    private let images: [UIImage]

    init(manifest: Manifest, bundle: Data) throws {
        guard manifest.frames.count == manifest.yaws.count * manifest.pitches.count,
              !manifest.frames.isEmpty else { throw APIError.invalidData }
        var imgs: [UIImage] = []
        imgs.reserveCapacity(manifest.frames.count)
        for f in manifest.frames {
            let start = bundle.startIndex + f.offset
            guard f.offset >= 0, f.length > 0, f.offset + f.length <= bundle.count,
                  let img = UIImage(data: bundle.subdata(in: start..<(start + f.length)))
            else { throw APIError.invalidData }
            imgs.append(img.preparingForDisplay() ?? img)   // 預先解碼，旋轉時才流暢
        }
        self.manifest = manifest
        self.images = imgs
    }

    var yawRange: ClosedRange<Double> { manifest.yaws.first!...manifest.yaws.last! }
    var pitchRange: ClosedRange<Double> { manifest.pitches.first!...manifest.pitches.last! }

    private func image(yawIndex: Int, pitchIndex: Int) -> UIImage {
        images[pitchIndex * manifest.yaws.count + yawIndex]
    }

    /// 取樣：最接近的 pitch 列，yaw 方向回傳相鄰兩張與混合權重
    func sample(yaw: Double, pitch: Double) -> (a: UIImage, b: UIImage, weight: Double) {
        let ps = manifest.pitches
        let pi = ps.indices.min(by: { abs(ps[$0] - pitch) < abs(ps[$1] - pitch) }) ?? 0

        let ys = manifest.yaws
        guard ys.count > 1 else {
            let img = image(yawIndex: 0, pitchIndex: pi)
            return (img, img, 0)
        }
        let y = min(max(yaw, ys.first!), ys.last!)
        var j = 0
        while j < ys.count - 2 && ys[j + 1] < y { j += 1 }
        let span = ys[j + 1] - ys[j]
        let w = span > 0 ? (y - ys[j]) / span : 0
        return (image(yawIndex: j, pitchIndex: pi), image(yawIndex: j + 1, pitchIndex: pi), w)
    }
}
