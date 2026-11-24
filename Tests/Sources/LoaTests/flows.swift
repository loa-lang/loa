import Loa
import Testing

enum LoaTestSuite {
    static let suite = TestSuite("loa", title: "Loa language") {
        Test("sources use the .loa extension") {
            try Expect.equal(Loa.fileExtension, "loa", "file extension")
        }
    }
}
