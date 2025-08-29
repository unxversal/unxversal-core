History
is entry needed for public functions
Enable notifications
Detailed Mode

Want to integrate Chef AI?

Ask me anything about Sui!


is entry needed for public functions


No, the entry modifier is not needed for public functions in Move on Sui. In fact, using both public and entry together is generally discouraged unless you have a very specific use case.

Why?
public functions can already be called from Programmable Transaction Blocks (PTBs).
entry is used to allow non-public functions to be called from PTBs, but it adds restrictions (e.g., all return types must have the drop ability).
Adding entry to a public function limits composability and is only meaningful in niche scenarios.
Example of unnecessary usage:

module a::m {
    public entry fun unnecessary_entry() {}
    entry public fun also_unnecessary() {}
}
This will trigger a linter warning:

entry on public functions limits composability as it adds restrictions, e.g. the type of each return value must have drop. entry on public is only meaningful in niche scenarios.
public functions can be called from PTBs. entry can be used to allow non-public functions to be called from PTBs, but it adds restrictions on the usage of input arguments and on the type of return values. Unless this public function interacts with an intricate set of other entry functions, the entry modifier should be removed.

How to suppress the warning (if you really need it):

#[allow(lint(public_entry))]
public entry fun suppress_unnecessary_public_entry() {}
Summary:

Use public for functions you want to be callable from outside the module.
Use entry only for non-public functions that need to be called from PTBs.
Avoid combining them unless you have a very specific reason.
Source:
Move linter: unnecessary public entry