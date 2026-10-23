import Foundation

extension SidebarGraph {
    /// The name a new Space gets until the person renames it, as Arc names them: "Space 2" when it will be the second
    /// Space, or the next number up when another Space already has that name.
    public var newSpaceTitle: String {
        let taken = Set(spaces.map(\.title))
        var number = spaces.count + 1
        while taken.contains("Space \(number)") { number += 1 }
        return "Space \(number)"
    }
}
