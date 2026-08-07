// spec: §7
import Foundation
import PaneCore
import PaneHarness

/// spec §7 import. The CSV parser is where a subtle bug is most expensive:
/// a column shift stores passwords as usernames, and a naive comma split
/// corrupts every password containing a comma — silently, in a file the user
/// then deletes.
public func importChecks(_ check: Check) {

    check.suite("Import — Safari CSV") { e in
        let csv = """
        Title,URL,Username,Password,Notes,OTPAuth
        Example,https://example.com,alice,hunter2,,
        Mail,https://mail.example.com,bob@example.com,s3cret,,
        """
        let r = CredentialImport.parseCSV(csv)
        e.equal(r.format, "Safari CSV", "detected by the OTPAuth column")
        e.equal(r.entries.count, 2, "both rows imported")
        e.equal(r.entries.first?.origin, "example.com", "origin derived from the URL")
        e.equal(r.entries.first?.password, "hunter2", "password from the right column")
        e.equal(r.entries.last?.username, "bob@example.com", "email usernames survive")
    }

    check.suite("Import — Chrome CSV with different column order") { e in
        // Columns BY NAME, not position. Chrome's order differs from Safari's,
        // and reading by index would store the password as the username.
        let csv = """
        name,url,username,password,note
        Example,https://example.com,alice,hunter2,
        """
        let r = CredentialImport.parseCSV(csv)
        e.equal(r.format, "Chrome CSV", "no OTPAuth column")
        e.equal(r.entries.first?.username, "alice", "username column found by name")
        e.equal(r.entries.first?.password, "hunter2", "password column found by name")
    }

    check.suite("Import — columns are matched by name, not position") { e in
        // Password BEFORE username. Positional parsing would swap them and
        // store the secret as an account name, in plain sight.
        let csv = """
        url,password,username
        https://example.com,hunter2,alice
        """
        let r = CredentialImport.parseCSV(csv)
        e.equal(r.entries.first?.username, "alice", "username still correct when reordered")
        e.equal(r.entries.first?.password, "hunter2", "password still correct when reordered")
    }

    check.suite("Import — quoted fields, commas and newlines in passwords") { e in
        let csv = "url,username,password\n"
            + "https://example.com,alice,\"pa,ss\"\n"
            + "https://b.example.com,bob,\"line1\nline2\"\n"
            + "https://c.example.com,carol,\"quo\"\"te\"\n"
        let r = CredentialImport.parseCSV(csv)
        e.equal(r.entries.count, 3, "all three rows survive")
        e.equal(r.entries[0].password, "pa,ss", "a comma inside quotes is not a separator")
        e.equal(r.entries[1].password, "line1\nline2", "an embedded newline does not split the row")
        e.equal(r.entries[2].password, "quo\"te", "\"\" is an escaped quote")
    }

    check.suite("Import — non-https is skipped WITH a reason") { e in
        let csv = """
        url,username,password
        http://insecure.example.com,alice,hunter2
        https://ok.example.com,bob,hunter3
        """
        let r = CredentialImport.parseCSV(csv)
        e.equal(r.entries.count, 1, "only the https row is imported")
        e.equal(r.skipped.count, 1, "the other is reported, not silently dropped")
        e.that(r.skipped.first?.contains("insecure.example.com") == true,
               "and the reason names the row, because '1 skipped' is not information")
    }

    check.suite("Import — bare hosts and malformed rows") { e in
        let csv = """
        url,username,password
        example.com,alice,hunter2
        ,bob,hunter3
        https://d.example.com,,hunter4
        """
        let r = CredentialImport.parseCSV(csv)
        e.equal(r.entries.count, 1, "a bare host is assumed https and imported")
        e.equal(r.entries.first?.origin, "example.com", "and resolves correctly")
        e.equal(r.skipped.count, 2, "the empty-url and empty-username rows are reported")
    }

    check.suite("Import — an unrecognised header fails loudly") { e in
        let r = CredentialImport.parseCSV("a,b,c\n1,2,3")
        e.equal(r.entries.count, 0, "nothing is imported from a file we do not understand")
        e.that(r.skipped.first?.contains("could not find") == true,
               "and it says so rather than reporting an empty success")
    }
}
