import SwiftUI

struct ProjectFilterView: View {
    let groups: [ProjectGroup]
    @Binding var selectedGroup: String?

    var body: some View {
        HStack {
            Picker("Project", selection: $selectedGroup) {
                Text("All Projects").tag(nil as String?)
                ForEach(groups) { group in
                    Text("\(group.name) (\(group.projectDirs.count))")
                        .tag(group.name as String?)
                }
            }
            .pickerStyle(.menu)
            .font(Theme.Font.body)
            .tint(Theme.Palette.accent)
            .frame(maxWidth: .infinity)
        }
    }
}
