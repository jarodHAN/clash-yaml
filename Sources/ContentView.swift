import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.isRunning ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text("ClashVPN")
                    .font(.headline)
                Spacer()
                Text("mihomo \(state.version)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                if state.isRunning {
                    Button("停止") { state.stop() }
                } else {
                    Button("启动") { state.start() }
                }
                Button(state.systemProxyOn ? "关闭代理" : "系统代理") {
                    state.setSystemProxy(!state.systemProxyOn)
                }
                .disabled(!state.isRunning)
                Button("刷新") { state.refreshProxies() }
                    .disabled(!state.isRunning)
            }

            if state.isRunning {
                Picker("模式", selection: Binding(
                    get: { state.mode },
                    set: { state.setMode($0) }
                )) {
                    Text("规则").tag("rule")
                    Text("全局").tag("global")
                    Text("直连").tag("direct")
                }
                .pickerStyle(.segmented)
            }

            HStack {
                Text("↑ \(formatSpeed(state.upSpeed))   ↓ \(formatSpeed(state.downSpeed))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            Divider()

            HStack {
                Text("代理节点").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("测速全部") {
                    for g in state.groups { state.testAll(group: g) }
                }
                .font(.caption2)
                .disabled(state.groups.isEmpty)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(state.groups) { group in
                        GroupRow(group: group)
                            .environmentObject(state)
                    }
                }
            }
            .frame(maxHeight: 250)

            Divider()

            HStack(spacing: 6) {
                TextField("订阅 URL（留空为直连）", text: $state.subscriptionURL)
                    .textFieldStyle(.roundedBorder)
                Button("应用") { state.applySubscription() }
                Button("更新") { state.updateSubscription() }
                    .disabled(!state.isRunning)
            }

            Divider()

            Text("日志").font(.caption).foregroundColor(.secondary)
            ScrollView {
                Text(state.logs.joined(separator: "\n"))
                    .font(.system(size: 9, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 80)

            if !state.statusMessage.isEmpty {
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    func formatSpeed(_ v: Double) -> String {
        if v > 1024 * 1024 { return String(format: "%.1f MB/s", v / 1024 / 1024) }
        if v > 1024 { return String(format: "%.1f KB/s", v / 1024) }
        return String(format: "%.0f B/s", v)
    }
}

struct GroupRow: View {
    @EnvironmentObject var state: AppState
    let group: Proxy

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(group.name)
                    .font(.caption.bold())
                Spacer()
                Button("测速") { state.testAll(group: group) }
                    .font(.caption2)
            }
            let nodes = group.all ?? []
            if nodes.isEmpty {
                Text("（无节点）").font(.caption2).foregroundColor(.secondary)
            } else {
                ForEach(nodes, id: \.self) { node in
                    nodeRow(node: node, selected: group.now == node)
                }
            }
        }
    }

    private func nodeRow(node: String, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(selected ? .green : Color.secondary)
                .font(.caption2)
            Text(node)
                .font(.caption)
                .foregroundColor(selected ? .primary : .secondary)
            Spacer()
            if let d = state.delay(for: node, group: group.name) {
                Text(d >= 0 ? "\(d)ms" : "超时")
                    .font(.caption2)
                    .foregroundColor(delayColor(d))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { state.selectNode(group: group.name, node: node) }
    }

    private func delayColor(_ d: Int) -> Color {
        if d < 0 { return .red }
        if d < 150 { return .green }
        if d < 300 { return .yellow }
        return .orange
    }
}
