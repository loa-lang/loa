# Loa

A small language in which an agent composes capabilities into programs, instead of calling
tools one request at a time.

```
page survey {
    let found = mail.search(
        account: "levi",
        text: "invoice",
        since: date.days_ago(7)
    );

    let hits = found.messages.where(
        .unread
    );
}
```

- Literal values are Frame's (`.{ .field = value }`, `.case(value)`, arrays, block strings).
- Names resolve through a catalog supplied by the host; the language has no authority of its
  own. Every call goes through the host's permission and approval checks.
- Status: early. The grammar, checker and interpreter are being built.

Tests: `sbm test` (nested package in `Tests/`, product `t_loa`).
