import SwiftUI
import AgentMasterCore

public struct TodoPanel: View {
    let todos: [TodoItem]

    public init(todos: [TodoItem]) {
        self.todos = todos
    }

    public var body: some View {
        if todos.isEmpty {
            EmptyHint("No tasks yet")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(todos) { todo in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(StatusGlyph.symbol(for: todo.status)).foregroundStyle(Color(hex: StatusGlyph.colorHex(for: todo.status)))
                        Text(todo.subject)
                            .foregroundStyle(todo.status == .completed ? Palette.muted : Palette.text)
                            .lineLimit(2)
                    }
                    .font(MuseFont.body)
                }
            }
        }
    }
}
