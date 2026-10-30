#if DEBUG
import Foundation

/// Synthetic sent mail for opt-in native writing-style checks. No real mail is copied.
enum WritingStyleAuditFixtures {
    static func message(index: Int, formal: Bool) -> String {
        if formal {
            return """
            Guten Tag,

            vielen Dank für Ihre Rückmeldung zum Entwurf \(index + 1). Ich habe die Unterlagen geprüft. Die beschriebenen Schritte sind für mich nachvollziehbar.

            Bitte senden Sie mir die überarbeitete Fassung, sobald die offenen Punkte geklärt sind. Anschließend kann ich die Freigabe bestätigen.

            Mit freundlichen Grüßen
            Second Audit

            Am Mittwoch schrieb River:
            > This quoted text must not influence the learned style.
            """
        }
        return """
        Hey River,

        Looks good! I've checked draft \(index + 1) and we're ready to go. Can you send the updated notes when you've got a minute?

        I'll take care of the checklist. No rush on the rest :)

        Cheers,
        UI Audit

        On Wednesday, River wrote:
        > This quoted text must not influence the learned style.
        """
    }
}
#endif
