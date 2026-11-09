import Photos
import SwiftUI

/// 저장된 박스로 사진에서 얼굴이나 반려동물 부분만 잘라 원형으로 보여줍니다.
struct SubjectThumbnail: View {
    let subject: StoredSubject?
    var size: CGFloat = 64
    @State private var image: PlatformImage?

    private static let cache = NSCache<NSNumber, PlatformImage>()

    var body: some View {
        Circle()
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: subject?.species.isPet == true ? "pawprint.fill" : "person.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .task(id: subject?.id) { await load() }
    }

    private func load() async {
        guard let subject else { image = nil; return }
        if let cached = Self.cache.object(forKey: NSNumber(value: subject.id)) {
            image = cached
            return
        }
        guard let asset = PhotoLibrary.assets(withIDs: [subject.assetID])[subject.assetID],
              let source = await PhotoLibrary.analysisImage(
                for: asset,
                side: PhotoLibrary.subjectAnalysisSide,
                contentMode: .aspectFit,
                allowNetwork: true
              ),
              let upright = UprightImage.make(source.cgImage, orientation: source.orientation),
              let crop = UprightImage.squareCrop(upright, box: subject.box, padding: subject.species.isPet ? 0.1 : 0.5) else { return }
        let result = PlatformImage(cgImageValue: crop)
        Self.cache.setObject(result, forKey: NSNumber(value: subject.id))
        image = result
    }
}

extension Species {
    var title: String {
        switch self {
        case .person: "사람"
        case .dog: "강아지"
        case .cat: "고양이"
        }
    }

    /// 잘못 묶인 사진을 뺄 때 쓰는 말. 받침에 따라 조사가 달라서 문장째로 둡니다.
    var notThisOne: String {
        self == .person ? "이 사람이 아니에요" : "이 아이가 아니에요"
    }
}
