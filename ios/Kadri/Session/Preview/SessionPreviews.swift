#if DEBUG
import SwiftUI
import KadriCore

struct SessionPreview: View {
    let state: SessionPreviewState
    @State private var model: SessionModel

    init(_ state: SessionPreviewState) {
        self.state = state
        _model = State(initialValue: state.makeModel())
    }

    var body: some View {
        SessionScreen(model: model, keyframeProvider: { Data() }) {
            Color(hex: "#a9a79e")
        }
        .task { await state.prepare(model) }
    }
}

#Preview("მზადაა") { SessionPreview(.idle) }
#Preview("აღწერა") { SessionPreview(.describing) }
#Preview("სკანი") { SessionPreview(.scanning) }
#Preview("ნაწილები") { SessionPreview(.parts) }
#Preview("პირველი ნაბიჯის მოლოდინი") { SessionPreview(.waiting) }
#Preview("სტრიმინგი") { SessionPreview(.streaming) }
#Preview("ნაბიჯები") { SessionPreview(.steps) }
#Preview("დასრულდა") { SessionPreview(.done) }
#Preview("შეცდომა") { SessionPreview(.error) }
#endif
