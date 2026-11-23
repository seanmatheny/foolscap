import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The icons a Reference cover can carry: a curated set of SF Symbols in groups (there
/// is no public list of every symbol), each found by its name's words, its group's
/// name and a few extra words. Symbols this system lacks are dropped when first read.
enum ReferenceSymbols {
    struct Group: Identifiable {
        let title: String
        let symbols: [String]
        var id: String { title }
    }

    /// Extra words a search finds a symbol by, beyond its own name.
    static let keywords: [String: String] = [
        "fork.knife": "food recipe cooking kitchen meal",
        "cup.and.saucer.fill": "coffee tea cafe",
        "birthday.cake.fill": "birthday party celebration",
        "cart.fill": "shopping groceries",
        "house.fill": "home",
        "wrench.and.screwdriver.fill": "tools repair diy maintenance",
        "hammer.fill": "tools diy build",
        "lightbulb.fill": "idea",
        "briefcase.fill": "work job office",
        "building.2.fill": "office company work",
        "airplane": "travel flight trip holiday",
        "suitcase.fill": "travel packing luggage trip",
        "car.fill": "vehicle drive",
        "heart.fill": "love health favourite",
        "cross.case.fill": "medical first aid health doctor",
        "pills.fill": "medicine medication health",
        "dumbbell.fill": "gym fitness exercise workout",
        "figure.run": "running exercise fitness",
        "creditcard.fill": "money bank card finance payment",
        "banknote.fill": "money cash finance",
        "dollarsign.circle.fill": "money finance budget",
        "chart.pie.fill": "budget finance",
        "desktopcomputer": "computer mac tech",
        "laptopcomputer": "computer mac tech",
        "server.rack": "server backup tech",
        "wifi": "network internet",
        "key.fill": "password security login",
        "lock.fill": "security password",
        "leaf.fill": "garden plant nature",
        "tree.fill": "garden nature outdoors",
        "pawprint.fill": "pet dog cat animal",
        "person.2.fill": "people family friends contacts",
        "graduationcap.fill": "school study education university",
        "book.fill": "reading books library",
        "books.vertical.fill": "reading library",
        "music.note": "music song",
        "gamecontroller.fill": "games play",
        "gift.fill": "present birthday christmas",
        "calendar": "date schedule",
        "phone.fill": "contacts call",
        "envelope.fill": "mail email letter",
        "map.fill": "travel directions",
        "camera.fill": "photo photography",
        "film.fill": "movie cinema watch",
        "paintbrush.fill": "art painting design",
        "checklist": "todo list tasks",
        "list.bullet.clipboard.fill": "checklist procedure list",
        "doc.text.fill": "document notes",
        "terminal.fill": "code command shell",
        "chevron.left.forwardslash.chevron.right": "code programming html",
        "bolt.fill": "electric power energy",
        "flame.fill": "fire heating gas",
        "drop.fill": "water plumbing",
        "thermometer.medium": "heating temperature",
        "sun.max.fill": "weather summer",
        "snowflake": "winter cold weather",
        "bicycle": "bike cycling",
        "tram.fill": "train transport commute",
        "bus.fill": "transport commute",
        "fuelpump.fill": "car petrol gas",
        "tshirt.fill": "clothes",
        "bed.double.fill": "bedroom sleep",
        "sofa.fill": "living room furniture",
        "stethoscope": "doctor medical health",
        "brain.head.profile": "mind thinking mental health",
        "globe": "world internet language",
        "flag.fill": "country goal",
        "star.fill": "favourite",
        "bookmark.fill": "reference save",
    ]

    static let groups: [Group] = [
        Group(title: "Notes", symbols: [
            "book.fill", "books.vertical.fill", "book.closed.fill", "bookmark.fill", "doc.text.fill", "note.text",
            "list.bullet", "checklist", "list.bullet.clipboard.fill", "text.book.closed.fill", "magazine.fill",
            "newspaper.fill", "archivebox.fill", "folder.fill", "tray.full.fill", "paperclip", "pencil", "highlighter",
            "quote.bubble.fill", "lightbulb.fill", "star.fill", "flag.fill", "tag.fill", "pin.fill", "questionmark.circle.fill",
            "info.circle.fill", "exclamationmark.triangle.fill",
        ]),
        Group(title: "Work", symbols: [
            "briefcase.fill", "building.2.fill", "building.columns.fill", "person.crop.rectangle.fill", "person.badge.key.fill",
            "chart.bar.fill", "chart.line.uptrend.xyaxis", "chart.pie.fill", "calendar", "clock.fill", "alarm.fill",
            "timer", "hourglass", "envelope.fill", "paperplane.fill", "phone.fill", "video.fill", "bubble.left.and.bubble.right.fill",
            "megaphone.fill", "signature", "printer.fill", "scissors", "ruler.fill", "graduationcap.fill", "studentdesk",
        ]),
        Group(title: "Home", symbols: [
            "house.fill", "key.fill", "lock.fill", "door.left.hand.closed", "sofa.fill", "bed.double.fill", "lamp.desk.fill",
            "lightbulb.led.fill", "washer.fill", "refrigerator.fill", "oven.fill", "shower.fill", "bathtub.fill", "toilet.fill",
            "wrench.and.screwdriver.fill", "hammer.fill", "screwdriver.fill", "paintbrush.fill", "paintbrush.pointed.fill",
            "spigot.fill", "drop.fill", "flame.fill", "bolt.fill", "thermometer.medium", "fan.fill", "powerplug.fill",
            "trash.fill", "shippingbox.fill",
        ]),
        Group(title: "Food", symbols: [
            "fork.knife", "cup.and.saucer.fill", "mug.fill", "wineglass.fill", "birthday.cake.fill", "carrot.fill",
            "fish.fill", "takeoutbag.and.cup.and.straw.fill", "frying.pan.fill", "basket.fill", "cart.fill", "bag.fill",
            "storefront.fill", "waterbottle.fill",
        ]),
        Group(title: "Travel", symbols: [
            "airplane", "suitcase.fill", "suitcase.rolling.fill", "car.fill", "bus.fill", "tram.fill", "ferry.fill",
            "bicycle", "scooter", "fuelpump.fill", "map.fill", "mappin.and.ellipse", "location.fill", "globe",
            "globe.europe.africa.fill", "globe.asia.australia.fill", "tent.fill", "mountain.2.fill", "beach.umbrella.fill",
            "ticket.fill", "passport", "binoculars.fill", "camera.fill", "signpost.right.fill",
        ]),
        Group(title: "Health", symbols: [
            "heart.fill", "cross.case.fill", "pills.fill", "stethoscope", "bandage.fill", "syringe.fill", "brain.head.profile",
            "lungs.fill", "eye.fill", "ear.fill", "allergens.fill", "dumbbell.fill", "figure.run", "figure.walk",
            "figure.yoga", "figure.pool.swim", "bed.double.circle.fill", "moon.zzz.fill", "drop.degreesign.fill",
        ]),
        Group(title: "Money", symbols: [
            "creditcard.fill", "banknote.fill", "dollarsign.circle.fill", "sterlingsign.circle.fill", "eurosign.circle.fill",
            "yensign.circle.fill", "chart.bar.doc.horizontal.fill", "building.columns.circle.fill", "percent",
            "receipt.fill", "wallet.pass.fill", "giftcard.fill", "cart.circle.fill", "scalemass.fill",
        ]),
        Group(title: "Tech", symbols: [
            "desktopcomputer", "laptopcomputer", "iphone", "ipad", "applewatch", "keyboard.fill", "printer.dotmatrix.fill",
            "server.rack", "externaldrive.fill", "internaldrive.fill", "cpu.fill", "memorychip.fill", "wifi",
            "antenna.radiowaves.left.and.right", "network", "cloud.fill", "icloud.fill", "terminal.fill",
            "chevron.left.forwardslash.chevron.right", "curlybraces", "gearshape.fill", "gearshape.2.fill",
            "cable.connector", "battery.100", "tv.fill", "headphones", "airpods", "gamecontroller.fill", "qrcode",
            "lock.shield.fill", "key.horizontal.fill",
        ]),
        Group(title: "Nature", symbols: [
            "leaf.fill", "tree.fill", "camera.macro", "laurel.leading", "carrot", "pawprint.fill", "dog.fill", "cat.fill",
            "bird.fill", "fish", "ladybug.fill", "ant.fill", "tortoise.fill", "hare.fill", "sun.max.fill", "moon.fill",
            "cloud.sun.fill", "cloud.rain.fill", "snowflake", "wind", "tornado", "drop", "flame", "mountain.2",
            "water.waves", "globe.americas.fill", "sparkles",
        ]),
        Group(title: "People", symbols: [
            "person.fill", "person.2.fill", "person.3.fill", "figure.and.child.holdinghands", "figure.2.and.child.holdinghands",
            "person.crop.circle.fill", "person.text.rectangle.fill", "person.wave.2.fill", "hand.wave.fill",
            "hands.clap.fill", "hand.thumbsup.fill", "face.smiling.fill", "heart.circle.fill", "gift.fill",
            "balloon.2.fill", "party.popper.fill", "teddybear.fill", "stroller.fill",
        ]),
        Group(title: "Leisure", symbols: [
            "music.note", "music.note.list", "guitars.fill", "pianokeys", "film.fill", "theatermasks.fill", "popcorn.fill",
            "tv.inset.filled", "gamecontroller", "puzzlepiece.fill", "dice.fill", "paintpalette.fill", "camera.aperture",
            "photo.fill", "book", "sportscourt.fill", "soccerball", "basketball.fill", "tennis.racket", "figure.hiking",
            "figure.skiing.downhill", "sailboat.fill", "trophy.fill", "medal.fill", "crown.fill",
        ]),
        Group(title: "Objects", symbols: [
            "tshirt.fill", "eyeglasses", "bag.fill", "backpack.fill", "umbrella.fill", "crown", "hourglass.bottomhalf.filled",
            "lamp.floor.fill", "lightbulb", "flashlight.on.fill", "bell.fill", "gift", "shippingbox", "cube.fill",
            "puzzlepiece", "wand.and.stars", "magnifyingglass", "link", "anchor", "atom", "flask.fill", "testtube.2",
            "compass.drawing", "globe.desk.fill", "square.stack.3d.up.fill", "seal.fill", "shield.fill",
        ]),
    ]

    /// The groups with every symbol this system can draw, each listed once.
    @MainActor static let available: [Group] = {
        var seen = Set<String>()
        return groups.compactMap { group in
            let symbols = group.symbols.filter { exists($0) && seen.insert($0).inserted }
            return symbols.isEmpty ? nil : Group(title: group.title, symbols: symbols)
        }
    }()

    static func exists(_ name: String) -> Bool {
        #if canImport(AppKit)
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        UIImage(systemName: name) != nil
        #endif
    }

    /// The groups narrowed to symbols whose name, group or extra words carry every word typed.
    @MainActor static func matching(_ query: String) -> [Group] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return available }
        return available.compactMap { group in
            let symbols = group.symbols.filter { name in
                let hay = name.replacingOccurrences(of: ".", with: " ") + " " + group.title.lowercased() + " " + (keywords[name] ?? "")
                return words.allSatisfy { hay.contains($0) }
            }
            return symbols.isEmpty ? nil : Group(title: group.title, symbols: symbols)
        }
    }
}
