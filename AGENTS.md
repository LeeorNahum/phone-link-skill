# AGENTS.md

Rules for editing the **phone-link** skill. User-facing guidance lives in `SKILL.md`. `README.md` is the human skim layer.

## File roles

| File | Role |
| --- | --- |
| `SKILL.md` | When the skill applies, how to run the script, the command table, how to send, the phone's folders, privacy rules, and gotchas that change how output is read |
| `scripts/phone-texts.ps1` | Lists conversations, reads messages, and sends or drafts them through the Phone Link window with UI Automation |
| `README.md` | Short human summary |

## Design notes

- The description keeps a locality boundary: the skill applies only to an agent on the computer that runs Phone Link and holds the phone's storage folder. A description that lets a cloud or remote agent load it wastes that agent's context on a window it cannot reach.
- The skill reads the window, never Phone Link's database. Phone Link encrypts its message database with keys bound to its own app container, which a script running as the user cannot unwrap, and reading it would mean reimplementing a format that changes with each Phone Link update.
- The skill reaches the phone two ways: the script for texts, and plain file tools for the storage folder.
- Whether a send needs the user's confirmation is the user's call, made in their own instructions, so `SKILL.md` treats a request to send as the go-ahead and offers `-Draft` for everything else.
- Deleting, renaming, or overwriting phone files from the computer is blocked by Windows, which also notifies the user. The skill documents that limit and never works around it.
- Both lists in the window build only the rows near their view, so the script walks each one by setting its scroll percent in steps of half a view (the conversation list) or most of a view (the message pane) and collects rows as they appear. Faster steps miss rows. A minimized window builds no rows, so the script restores it with `SW_SHOWNOACTIVATE`, which takes no focus, and minimizes it again on every exit path. `-Draft` leaves it shown and brings it forward, since the user has to press Send.
- A conversation row's name is `Conversation with <participants>.` then `Unread messages.` when unread, then the preview. `threads` prints only the participants and the unread flag, never the preview.
- A message row's name is `Message from <sender>. <text>. <Mon d, yyyy h:mm tt> - <status>. <M/d/yyyy> at <h:mm tt>.`, with a trailing `, Press Tab to explore message content.` when it has an attachment or link. The short date is left unfilled on received messages, so the script reads the long date, taken from the right because a message's text can hold a date. The text comes from the row's `MessageBody` element, attachments from its `AttachmentsScrollViewer`, and the sender from the name up to the text. A `you` sender whose status does not start with `Sent` is `me (not sent)`.
- Every name carries invisible format characters around names, dates, and times. The script strips the whole `\p{Cf}` class, because Phone Link has used more than one kind.
- Rows are keyed by their full name, so two identical messages from one sender in the same minute collapse into one. The pane exposes no stable per-message id, since row containers are recycled as it scrolls. Rows found on each step up the pane go in front of those found before, so messages from the same minute keep the pane's order.
- Every time compared with the window's is cut to its minute, ticks included, because the window shows no seconds.
- `read` resolves a conversation by exact participants, then by the one conversation whose people are exactly the names given, then by the one that includes them all. `send` stops before the last step, because a name that reaches a group sends to people the user did not name. Exactly means each name fits a different person and no one is left over, a name fits a number's end only from 7 digits when sending, and a name given twice is refused, so overlapping names cannot stand in for someone unnamed. Both error with the candidates when several fit, because acting on the wrong conversation is worse than asking.
- After selecting a conversation, `read` and `send` wait for the message box's label to name it and for the previous conversation's messages to leave the pane, so neither reads or types into the conversation that was open before. Only the label's conversation part is compared, since the rest lists staged file names.
- A time bound names a span, the whole day or minute written: `-Since` begins where the span begins and `-Until` ends where it ends. It accepts the time format `read` prints and the one `-Json` prints, so a printed time goes straight back in and includes the message it came from. A `-Json` time must carry its zone, or it would shift by the offset.
- Lists arrive as one string through `-File`, so `-With`, `-From`, and `-Attach` are plain strings the script splits, names on commas and paths on `|`, which no Windows path contains.
- Each command rejects options it does not use, and an empty entry wherever a list filters. A silently ignored filter makes an unfiltered result look filtered. For the same reason `read` notes on stderr when a `-From` name fits nobody in the conversation. `error:` lines are written past the pipeline, so a failure inside a function whose output is captured still prints.
- Help is the script's comment block, printed from its own text.

## Sending

- `send` types with `ValuePattern.SetValue` on the `InputTextBox` and presses `SendMessageButton` with `InvokePattern`. Keystrokes would land in whatever window has focus, so the script sends none.
- The message box is labeled `Send a message from <SIM>, Conversation with <participants>.`, followed by the attachments once there are any. The script checks the recipients again before typing and right before Send, against that label or the new message's chips, and stops with nothing sent when they changed.
- A new conversation starts from `NewMessageButton`. Each recipient goes into the `To` box of `ContactSuggestionsBox`. A contact is chosen by invoking its row in `SuggestionsList`, whose two text parts are the contact's name and its number. A number with no contact is accepted by invoking the suggestion box itself, which stands for Enter. Each recipient becomes a chip in `ContactsScrollViewer`. Each step must add exactly one chip, the contact or number asked for, with the earlier chips unchanged. A new message that already has chips is refused, and one that fails while its recipients go in loses them again. The suggestion list fills in as Phone Link searches, so it is used once two reads agree. When the recipients already have a conversation, the new message turns into it and the chips go. On Send, a new message also turns into its conversation with a new message box, so every check after Send finds the box again.
- Images go in through `AttachImageButton`, then the popup's `BrowseButton`, which opens a standard Open dialog owned by the Phone Link window and run by `PickerHost`. The script finds it by owner and class, puts the path into the file name box with `WM_SETTEXT`, reads it back, and posts `IDOK`. The dialog filters to image types but takes any file whose full path is typed, and Phone Link stages it as an image, so the script checks the extension against the dialog's own filter before starting. Staged images show as `Remove image <n> of <n>` buttons in `ImagePreviewScrollHost`. Images are attached before the text is typed, the order that sent reliably in testing.
- `send` refuses when the box already holds text or images, so it never sends or clears what the user typed. Once it has typed, any failure before Send cancels an open picker, removes each staged image, and empties the text, only while the window still shows the same recipients, so it never clears another conversation. The error says so when the box could not be emptied, so nothing half-made waits for a later Send unnoticed.
- A `trap` turns any error the script did not foresee into one `error:` line, with the same cleanup before Send and the check-before-sending-again warning after it.
- Success is the conversation showing a new `Message from you` row, absent before Send, from the send minute on, with the same text and attachment presence, and a status starting with `Sent`. A row without a status is not success. Phone Link has crashed on Send, so the script reports a window that closed, and every error after Send tells the agent to check with `read` before sending again.
- Test sends go only to the user's own number, in the conversation with themselves, and only with their permission.

## Editing

- Keep the skill agnostic: no real names, phone numbers, device ids, or project references in any file.
- Bump `metadata.version` by the release-versioning skill's rules for skills.
- When Phone Link changes its window, inspect the tree with UI Automation against a conversation the user owns and update the script and the design notes together.
- Keep the script ASCII, so Windows PowerShell 5.1 reads it correctly, and write it for 5.1: no ternary or null-coalescing operators, no `Sort-Object -Stable`, and wrap any result whose `.Count` is read in `@()`, since 5.1 gives a single custom object no `.Count`.
- Quote frontmatter string values and keep bullets capitalized and parallel.
- Use no em dashes and no prose-joining semicolons.

## Before finishing

- `threads` returns the same count on repeated runs, with the window both open and minimized, and leaves a minimized window minimized.
- `read` works with the participants as printed and with a partial name, errors with the candidates on an ambiguous name, and each of `-Since`, `-Until`, `-From`, `-Grep`, `-Last`, and `-Json` changes the output as documented. `-With` and `-From` take two names separated by a comma.
- A time copied from `read`'s text output and one copied from its `-Json` output each work as `-Since` and as `-Until`, and each includes the message it was copied from.
- `send` to the user's own conversation succeeds with a two-line text, with an image and text, by number, and with the window minimized, and `-Draft` leaves the message in the box and refuses a second send over it.
- Every failure path prints one `error:` line and exits 1.
- `help` prints.
- The skill-forge validator passes.
- `SKILL.md` and `README.md` agree on the run route and the requirements.
