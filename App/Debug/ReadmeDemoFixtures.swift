#if DEBUG || TERN_PERFORMANCE
import Foundation

/// Fictional content for the opt-in README capture. The audit runtime supplies
/// in-memory stores and services; this flag alone never replaces a live account.
enum ReadmeDemoFixtures {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-audit")
            && ProcessInfo.processInfo.environment["TERN_README_SCREENSHOTS"] == "1"
    }

    static let date = Date(timeIntervalSince1970: 1_793_696_400)

    struct Mail: Sendable {
        let id: String
        let subject: String
        let sender: String
        let text: String
        let labels: Set<String>
        var attachment: String? = nil
    }

    static let studioMail: [Mail] = [
        .init(id: "collection", subject: "The autumn collection is ready", sender: "Maya Chen <maya@studio.example.invalid>", text: """
        Hi Alex,

        The autumn collection is ready for your final review. We have brought the photography, product stories, and launch schedule together in one place.

        Here is where we landed:

        • Photography — final selects approved
        • Product stories — copy and captions complete
        • Launch day — Thursday, 12 November

        The warmer palette works beautifully with the new materials. I have attached the collection notes so you can review the details before we meet.

        Could you take a look and send any final comments by Wednesday? Once we have your approval, I will share the complete package with the team.

        Thanks,
        Maya

        Maya Chen
        Design director · Northstar Studio
        """, labels: ["INBOX", "STARRED", "Label_1", "Label_2"], attachment: "Autumn collection notes.txt"),
        .init(id: "review", subject: "A few notes before tomorrow's design review", sender: "Oliver Reed <oliver@studio.example.invalid>", text: "The updated layouts are in the review folder. I would love your thoughts on the opening spread and the new typography.", labels: ["INBOX", "UNREAD", "Label_2"]),
        .init(id: "estimate", subject: "Print estimate for the November edition", sender: "Sophie Park <sophie@print.example.invalid>", text: "Here is the revised estimate for 500 copies on the textured stock we discussed. Delivery is included.", labels: ["INBOX", "UNREAD", "Label_3"], attachment: "November print estimate.txt"),
        .init(id: "workshop", subject: "Your place at the ceramics workshop", sender: "Clay House <hello@clay.example.invalid>", text: "We have saved you a seat for Saturday's hand-building workshop. All materials are included; just bring an apron.", labels: ["INBOX", "UNREAD", "Label_4"]),
        .init(id: "handoff", subject: "Website handoff: everything you need", sender: "Leo Martin <leo@studio.example.invalid>", text: "The component library, page templates, and export guide are ready. Let me know if anything is missing.", labels: ["INBOX", "STARRED", "Label_1"], attachment: "Website handoff.txt"),
        .init(id: "newsletter", subject: "Small studios, thoughtful spaces", sender: "The Design Letter <editor@letter.example.invalid>", text: "This week: a converted warehouse, a neighborhood bookshop, and a studio built around a single oak tree.", labels: ["INBOX", "Label_5"]),
        .init(id: "coffee", subject: "Coffee next week?", sender: "Jamie Ellis <jamie@example.invalid>", text: "I will be in town on Tuesday. There is a new little café near the station that I think you would like.", labels: ["INBOX", "Label_4"]),
        .init(id: "invoice", subject: "Your October invoice", sender: "Paper & Press <accounts@print.example.invalid>", text: "Thank you for working with us. Your October invoice is attached, with the project reference included.", labels: ["INBOX", "Label_3"], attachment: "October invoice.pdf"),
        .init(id: "research", subject: "Interview notes and the next round", sender: "Nora Williams <nora@studio.example.invalid>", text: "The first five interviews are complete. A few themes are emerging around navigation and finding saved items.", labels: ["INBOX", "UNREAD", "Label_1"]),
        .init(id: "reading", subject: "Three books for a quiet weekend", sender: "Chapter Books <hello@books.example.invalid>", text: "A collection of essays, a beautifully illustrated travel journal, and a novel we have been passing around the shop.", labels: ["INBOX", "Label_5"]),
        .init(id: "sent", subject: "Re: Studio open day", sender: "Alex Morgan <alex@studio.example.invalid>", text: "Thanks for putting this together. The afternoon works well; I will bring the printed samples.", labels: ["SENT", "Label_1"]),
        .init(id: "archive", subject: "Brand guidelines approved", sender: "Maya Chen <maya@studio.example.invalid>", text: "The final guidelines are approved. Thank you for all the care that went into this project.", labels: ["Label_2"])
    ]

    static let personalMail: [Mail] = [
        .init(id: "journey", subject: "Your weekend in Copenhagen", sender: "Juniper House <stay@juniper.example.invalid>", text: "We look forward to welcoming you. Here are your arrival details and a few favorite places nearby.", labels: ["INBOX", "UNREAD", "Label_1"], attachment: "Weekend itinerary.txt"),
        .init(id: "dinner", subject: "Sunday dinner at ours", sender: "Sam Rivera <sam@example.invalid>", text: "Come over around six. We are making pasta, and there is plenty of room for one more at the table.", labels: ["INBOX", "Label_2"]),
        .init(id: "trail", subject: "A good route for Saturday", sender: "Taylor Brooks <taylor@example.invalid>", text: "I found a gentle loop through the woods with a great view at the halfway point. The forecast looks clear.", labels: ["INBOX", "STARRED", "Label_2"]),
        .init(id: "receipt", subject: "Thanks for your order", sender: "Field Notes Shop <orders@shop.example.invalid>", text: "Your notebooks are on their way. The order summary and delivery details are attached.", labels: ["INBOX", "Label_3"], attachment: "Order summary.txt")
    ]
}
#endif
