import SwiftUI
struct Flight: Identifiable, Hashable { let id: String; let time: String; let price: String }
let flights = [
    Flight(id: "SkyJet 101", time: "11h 40m", price: "$612"),
    Flight(id: "Pacific 22", time: "12h 05m", price: "$540"),
    Flight(id: "Blue Heron 88", time: "10h 55m", price: "$701"),
    Flight(id: "Cedar 14", time: "13h 10m", price: "$455"),
    Flight(id: "Meridian 60", time: "14h 30m", price: "$399"),
    Flight(id: "Orbit 3", time: "10h 10m", price: "$1,240"),
    Flight(id: "Lantern 9", time: "11h 15m", price: "$820"),
]
let cities = ["Osaka Kansai (KIX)", "Sydney (SYD)", "Tokyo Haneda (HND)", "Tokyo Narita (NRT)", "Seoul Incheon (ICN)"]
let taken: Set<String> = ["1A","1B","1F","2A","2C","2F","3A","3B","4D","5A","5F"]
enum Route: Hashable { case allDestinations, results, seats(Flight), pay(Flight, String), done(Flight, String) }
struct Field: View {
    let title: String; let value: String; let icon: String
    var body: some View {
        HStack { Image(systemName: icon).foregroundStyle(.blue).accessibilityHidden(true)
            VStack(alignment: .leading) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline) }
            Spacer() }.padding(12).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
struct CityPicker: View {
    @Binding var city: String?; @Environment(\.dismiss) var dismiss; @State private var q = ""
    var body: some View {
        NavigationStack {
            List(cities.filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }, id: \.self) { c in
                Button(c) { city = c; dismiss() }
            }
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "City or airport")
            .navigationTitle("Where to?").navigationBarTitleDisplayMode(.inline)
        }
    }
}
struct Explore: View {
    @Binding var path: [Route]; @State private var to: String?; @State private var picking = false; @State private var swapped = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Image(systemName: "paperplane.fill").foregroundStyle(.white).padding(8).background(.indigo, in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
                    Text("Skylark").font(.title2.bold()); Spacer()
                    Image(systemName: "bell").padding(9).background(.thinMaterial, in: Circle()).accessibilityLabel("Alerts") }
                Text("Evening, traveller").foregroundStyle(.secondary)
                Text("Going somewhere?").font(.largeTitle.bold())
                VStack(spacing: 8) {
                    ZStack(alignment: .trailing) {
                        VStack(spacing: 8) {
                            Field(title: "From", value: swapped ? (to ?? "Where to?") : "San Francisco (SFO)", icon: "airplane.departure")
                            Button { picking = true } label: { Field(title: "To", value: to ?? "Where to?", icon: "airplane.arrival") }.buttonStyle(.plain)
                        }
                        Image(systemName: "arrow.up.arrow.down").padding(10).background(.background, in: Circle()).padding(.trailing, 8)
                            .accessibilityLabel("Swap").onTapGesture { swapped.toggle() }
                    }
                    HStack { Field(title: "Depart", value: "Fri, Nov 13", icon: "calendar"); Field(title: "Travelers", value: "1 adult", icon: "person.fill") }
                    Button { path.append(.results) } label: { Text("Search flights").bold().frame(maxWidth: .infinity).padding(12) }
                        .buttonStyle(.borderedProminent).disabled(to == nil)
                }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 22)).shadow(radius: 8)
                HStack { Text("Trending from San Francisco").font(.headline); Spacer()
                    Text("See all").foregroundStyle(.blue).onTapGesture { path.append(.allDestinations) } }
                HStack(spacing: 10) { ForEach([("Tokyo", "$612"), ("Sydney", "$988")], id: \.0) { c in
                    Button { } label: { VStack(alignment: .leading) { Text("from \(c.1)").font(.caption.bold()); Spacer(); Text(c.0).font(.headline) }
                        .padding(10).frame(maxWidth: .infinity, minHeight: 210, alignment: .leading).background(LinearGradient(colors: [.teal, .indigo], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white) }.buttonStyle(.plain) } }
            }.padding(.horizontal)
        }
        .sheet(isPresented: $picking) { CityPicker(city: $to) }
    }
}
struct Results: View {
    @Binding var path: [Route]
    var body: some View {
        List(flights) { f in
            Button { path.append(.seats(f)) } label: { VStack(alignment: .leading) { Text(f.id).font(.headline); HStack { Text(f.time); Spacer(); Text(f.price).bold() } } }.buttonStyle(.plain)
        }.navigationTitle("SFO to HND")
    }
}
struct Seats: View {
    let flight: Flight; @Binding var path: [Route]; @State private var pick: String?
    var body: some View {
        ScrollView { Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(1...20, id: \.self) { r in GridRow { ForEach(["A","B","C","D","E","F"], id: \.self) { l in
                let s = "\(r)\(l)"; let off = taken.contains(s); let win = l == "A" || l == "F"
                Button { pick = s } label: { Text(off ? "" : s).font(.caption.bold()).frame(width: 46, height: 40)
                    .background(pick == s ? Color.blue : off ? Color.gray.opacity(0.35) : win ? Color.cyan.opacity(0.3) : Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8)) }
                    .buttonStyle(.plain).disabled(off)
                    .accessibilityLabel(off ? "Seat \(s), taken" : "Seat \(s)\(win ? ", window" : "")")
            } } }
        }.padding() }
        .safeAreaInset(edge: .bottom) { Button { if let pick { path.append(.pay(flight, pick)) } } label: { Text(pick.map { "Continue with \($0)" } ?? "Choose a seat").bold().frame(maxWidth: .infinity).padding(10) }.buttonStyle(.borderedProminent).disabled(pick == nil).padding(.horizontal) }
        .navigationTitle("Rows 1 to 20, front first").navigationBarTitleDisplayMode(.inline)
    }
}
struct Pay: View {
    let flight: Flight; let seat: String; @Binding var path: [Route]; @State private var card = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(flight.id), seat \(seat)").font(.headline)
            Button { card = true } label: { HStack { Image(systemName: card ? "checkmark.circle.fill" : "circle").accessibilityHidden(true); Text("Visa ending 4242"); Spacer(); Text("Saved").foregroundStyle(.secondary) }.padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14)) }.buttonStyle(.plain)
            Button { } label: { HStack { Image(systemName: "plus").accessibilityHidden(true); Text("Add a new card"); Spacer() }.padding() }.buttonStyle(.plain)
            Spacer()
            Button { path.append(.done(flight, seat)) } label: { Text("Pay \(flight.price)").bold().frame(maxWidth: .infinity).padding(12) }.buttonStyle(.borderedProminent).disabled(!card)
        }.padding().navigationTitle("Payment")
    }
}
struct Booked: View {
    let flight: Flight; let seat: String
    var body: some View {
        VStack(spacing: 12) { Image(systemName: "checkmark.seal.fill").font(.system(size: 60)).foregroundStyle(.green).accessibilityHidden(true)
            Text("You're booked").font(.largeTitle.bold()); Text("\(flight.id), \(flight.time)"); Text("Seat \(seat)"); Text("Paid \(flight.price) with Visa 4242") }
        .navigationBarBackButtonHidden()
    }
}
struct Home: View {
    @State private var path: [Route] = []
    var body: some View {
        NavigationStack(path: $path) {
            Explore(path: $path).navigationDestination(for: Route.self) { r in
                switch r {
                case .allDestinations: List(["Tokyo", "Sydney", "Paris", "Lima"], id: \.self) { Text($0) }.navigationTitle("All destinations")
                case .results: Results(path: $path)
                case .seats(let f): Seats(flight: f, path: $path)
                case .pay(let f, let s): Pay(flight: f, seat: s, path: $path)
                case .done(let f, let s): Booked(flight: f, seat: s)
                }
            }
        }
    }
}
struct Root: View { var body: some View { TabView {
    Home().tabItem { Label("Explore", systemImage: "globe") }
    Text("No trips yet").tabItem { Label("Trips", systemImage: "suitcase.fill") }
    Text("Nothing saved").tabItem { Label("Saved", systemImage: "heart.fill") }
    Text("Your profile").tabItem { Label("Profile", systemImage: "person.circle.fill") }
} } }
@main struct SkylarkApp: App { var body: some Scene { WindowGroup { Root() } } }
