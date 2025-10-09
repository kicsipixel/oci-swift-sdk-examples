import OCIKit
import SwiftUI

// MARK: - Object Model for Tree
struct ObjectNode: Identifiable, Hashable {
    let id: ObjectSummary.ID
    let name: String
    let size: String?
    let createdAt: String?
    var children: [ObjectNode]?

    init(id: ObjectSummary.ID, name: String, size: String? = nil, createdAt: String? = nil, children: [ObjectNode]? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.createdAt = createdAt
        self.children = children
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ObjectNode, rhs: ObjectNode) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Main Screen
struct Mainscreen: View {
    @State private var showInspector: Bool = true
    @Environment(DataViewModel.self) private var vm
    @State private var showingAlert: Bool = false
    @AppStorage("compartmentId") private var compartmentId: String = ""
    @State private var errorMessage: String = ""
    @AppStorage("selection") private var selection = ""

    @State private var treeObjects: [ObjectNode] = []
    @State private var selectedID: ObjectSummary.ID?
    var selectedNode: ObjectNode? {
        findNode(in: treeObjects, matching: selectedID)
    }

    // MARK: - Date Formatter
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM yyyy, HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    var body: some View {
        VStack {
            Picker("Select a bucket:", selection: $selection) {
                ForEach(vm.buckets, id: \.name) { bucket in
                    Text(bucket.name)
                }
            }
            .padding()
            .onChange(of: selection) { _, newValue in
                Task {
                    do {
                        try await vm.listObjects(bucketName: newValue)
                        treeObjects = buildTree(from: vm.objects)
                    } catch {
                        errorMessage = error.localizedDescription
                        showingAlert = true
                    }
                }
            }

            List(selection: $selectedID) {
                OutlineGroup(treeObjects, children: \.children) { node in
                    Text(node.name)
                        .tag(node.id)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 300)

            if let s = selectedID {
                Text("Selected: \(s)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .inspector(isPresented: $showInspector) {
            InspectorView(node: selectedNode)
        }
        .task {
            do {
                try await vm.getNamespace()
                try await vm.listBuckets()
                try await vm.listObjects(bucketName: UserDefaults.standard.string(forKey: "bucketName") ?? "")
                treeObjects = buildTree(from: vm.objects)
            } catch {
                errorMessage = error.localizedDescription
                showingAlert = true
            }
        }
        .alert("Error happened", isPresented: $showingAlert) {
            Button("Got it!", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .toolbar {
            ToolbarItemGroup {
                Text("BucketView")
                    .bold()
                    .font(.title3)

                Button(action: { showInspector.toggle() }) {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }
            }
        }
    }

    // MARK: - Build hierarchical tree from flat paths
    func buildTree(from rawObjects: [ObjectSummary]) -> [ObjectNode] {
        var root: [String: ObjectNode] = [:]

        for obj in rawObjects {
            let components = obj.name.split(separator: "/").map(String.init)
            let sizeString = obj.size.map { "\($0) bytes" }
            let createdString = obj.timeCreated.map { Self.dateFormatter.string(from: $0) }
            insertNode(into: &root, components: components, id: obj.id, size: sizeString, createdAt: createdString)
        }

        return Array(root.values).sorted(by: { $0.name < $1.name })
    }

    // Recursive insertion
    private func insertNode(
        into dict: inout [String: ObjectNode],
        components: [String],
        id: ObjectSummary.ID,
        size: String?,
        createdAt: String?
    ) {
        guard let first = components.first else { return }

        if components.count == 1 {
            dict[first] = ObjectNode(id: id, name: first, size: size, createdAt: createdAt, children: nil)
        } else {
            if dict[first] == nil {
                dict[first] = ObjectNode(id: ObjectSummary.ID(), name: first, children: [])
            }

            var childDict: [String: ObjectNode] = [:]
            if let children = dict[first]?.children {
                for child in children {
                    childDict[child.name] = child
                }
            }

            insertNode(into: &childDict, components: Array(components.dropFirst()), id: id, size: size, createdAt: createdAt)
            dict[first]?.children = Array(childDict.values).sorted(by: { $0.name < $1.name })
        }
    }

    func findNode(in nodes: [ObjectNode], matching id: ObjectSummary.ID?) -> ObjectNode? {
        guard let id else { return nil }
        for node in nodes {
            if node.id == id {
                return node
            }
            if let child = findNode(in: node.children ?? [], matching: id) {
                return child
            }
        }
        return nil
    }
}

// MARK: - Preview
#Preview {
    Mainscreen()
        .environment(DataViewModel.preview)
}
