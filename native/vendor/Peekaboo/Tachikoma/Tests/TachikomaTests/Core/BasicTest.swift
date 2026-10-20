import Foundation
import Testing

struct BasicTests {
    @Test
    func `Simple math test`() {
        #expect(2 + 2 == 4)
    }

    @Test
    func `String test`() {
        #expect("hello".uppercased() == "HELLO")
    }
}
