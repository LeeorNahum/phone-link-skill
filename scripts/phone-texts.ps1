<#
.SYNOPSIS
Reads and sends the paired phone's texts through the Phone Link window with Windows UI Automation.

.DESCRIPTION
Commands:
  threads              Every conversation in the window's list, newest first, with its
                       participants and whether it has unread messages. No message text.
  read <conversation>  One conversation's messages, oldest first.
  send <conversation>  Types a message into Phone Link and presses Send, then prints the
                       message as the conversation shows it.
  help                 This text.

A <conversation> is its participants as threads prints them, or names separated by commas
that pick out exactly one conversation. send also takes names or numbers that no
conversation has yet, and starts a new one with them.

Options:
  -With <name>[,<name>]  threads: only conversations that include every name. A name with
                         digits also matches the end of a phone number.
  -Since <when>          read: messages at or after <when>.
  -Until <when>          read: messages up to and including <when>.
  -From <name>[,<name>]  read: only messages whose sender contains a name, or whose number
                         ends with its digits. "me" is the phone's owner, messages not yet
                         sent included, and "me (not sent)" is those alone.
  -Grep <regex>          read: only messages matching this case-insensitive .NET regex.
  -Last <n>              read: only the newest <n> of the messages that pass the other filters.
  -Text <text>           send: the message. A line break in it stays a line break.
  -Attach <path>[|<path>]
                         send: image files to attach, full paths separated by |. Phone Link
                         sends .bmp, .dib, .gif, .jpg, .jpeg, .pjpeg, .png, .tif, .tiff, and .ico.
  -Draft                 send: leave the message in Phone Link's message box, unsent, and
                         bring the window forward for the user to press Send.
  -Json                  threads, read: one JSON object per line.

A <when> is a local day as yyyy-MM-dd, or a local minute the way the text output prints it
or the way -Json prints it. A bound covers the whole day or minute written.

The script opens Phone Link when it is closed and needs no foreground window. read and
send switch the window to their conversation. read and threads never type, click, or send.
send types and presses buttons through UI Automation, with no keystrokes or mouse.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File phone-texts.ps1 threads -With "Alex"
powershell -NoProfile -ExecutionPolicy Bypass -File phone-texts.ps1 read "Alex Doe" -Since 2026-01-05
powershell -NoProfile -ExecutionPolicy Bypass -File phone-texts.ps1 send "Alex Doe" -Text "On my way"
#>
param(
  [Parameter(Position = 0)][string]$Command,
  [Parameter(Position = 1)][string]$Conversation,
  [string]$With,
  [string]$Since,
  [string]$Until,
  [string]$From,
  [string]$Grep,
  [int]$Last = -1,
  [string]$Text,
  [string]$Attach,
  [switch]$Draft,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'

$script:minimizedWindow = $null
$script:composed = $false
$script:sendPressed = $false
$script:addingChips = $false
# Any error the script did not foresee still ends in one error line, with the box emptied, and after Send with the warning that it may have gone out.
trap {
  if ($script:sendPressed) {
    Restore-Window
    [Console]::Out.WriteLine("error: after Send was pressed: $($_.Exception.Message.Trim().TrimEnd('.')). The message may have been sent. $($script:check)")
    exit 1
  }
  Fail $_.Exception.Message
}
# A minimized window builds no rows, so a run restores it without focus and minimizes it again on every way out.
function Restore-Window { if ($script:minimizedWindow) { [void][PhoneTexts.Native]::ShowWindow($script:minimizedWindow, 7); $script:minimizedWindow = $null } }
function Fail([string]$message) {
  if ($script:addingChips) { $script:addingChips = $false; try { Remove-Chips; (Pattern (Get-Input) ([System.Windows.Automation.ValuePattern])).SetValue('') } catch { } }
  if ($script:composed -and -not (Clear-Compose)) { $message += " The message box could not be emptied, so empty it in Phone Link before anything else is sent." }
  Restore-Window
  # Written past the pipeline, so a failure inside a function whose output is captured still prints.
  [Console]::Out.WriteLine("error: $message")
  exit 1
}

$allowed = @{
  threads = @('Command', 'With', 'Json')
  read    = @('Command', 'Conversation', 'Since', 'Until', 'From', 'Grep', 'Last', 'Json')
  send    = @('Command', 'Conversation', 'Text', 'Attach', 'Draft')
  help    = @('Command')
}
if (-not $Command) { $Command = 'help' }
if (-not $allowed.ContainsKey($Command)) { Fail "unknown command `"$Command`". Commands: threads, read, send, help." }
foreach ($key in $PSBoundParameters.Keys) {
  if ($allowed[$Command] -notcontains $key) { Fail "$Command does not take -$key." }
}
# Help is the comment block above, printed from the script's own text.
if ($Command -eq 'help') {
  $source = $MyInvocation.MyCommand.ScriptBlock.ToString()
  Write-Output ($source.Substring($source.IndexOf('<#') + 2, $source.IndexOf('#>') - $source.IndexOf('<#') - 2).Trim())
  exit 0
}
if ($Command -in 'read', 'send' -and -not ($Conversation -and $Conversation.Trim())) { Fail "$Command needs a conversation, as threads prints its participants." }

# Lists arrive as one string when the script runs with -File, so the script splits them itself.
function Split-List([string]$value, [string]$separator, [string]$option) {
  $parts = @($value -split $separator | ForEach-Object { $_.Trim() })
  if ($parts -contains '') { Fail "$option has an empty entry." }
  $parts
}
$withNames = @(if ($PSBoundParameters.ContainsKey('With')) { Split-List $With ',' '-With' })
$fromNames = @(if ($PSBoundParameters.ContainsKey('From')) { Split-List $From ',' '-From' })
$attachPaths = @(if ($PSBoundParameters.ContainsKey('Attach')) { Split-List $Attach '\|' '-Attach' })
if ($PSBoundParameters.ContainsKey('Last') -and $Last -lt 1) { Fail '-Last needs a whole number of 1 or more.' }

$us = [Globalization.CultureInfo]::GetCultureInfo('en-US')

# The window shows times to the minute, so every time compared with them is cut to its minute.
function Get-Minute([datetime]$t) { $t.Date.AddHours($t.Hour).AddMinutes($t.Minute) }

# A bound names a span, the whole day or minute written, returned as its start and its end.
function Get-Span([string]$value, [string]$option) {
  $t = ($value.Trim() -replace '^[A-Za-z]{3} ', '')
  $day = [datetime]::MinValue
  if ([datetime]::TryParseExact($t, 'yyyy-MM-dd', $us, 'None', [ref]$day)) { return @($day, $day.AddDays(1)) }
  foreach ($format in 'yyyy-MM-dd hh:mmtt', 'yyyy-MM-dd h:mmtt', 'yyyy-MM-dd hh:mm tt', 'yyyy-MM-dd h:mm tt', 'yyyy-MM-dd HH:mm') {
    $minute = [datetime]::MinValue
    if ([datetime]::TryParseExact($t, $format, $us, 'None', [ref]$minute)) { return @($minute, $minute.AddMinutes(1)) }
  }
  if ($t -match 'T.*([+-]\d{2}:\d{2}|Z)$') {
    $zoned = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($t, $us, 'None', [ref]$zoned)) {
      $start = Get-Minute $zoned.LocalDateTime
      return @($start, $start.AddMinutes(1))
    }
  }
  Fail "-$option `"$value`" is not a day as yyyy-MM-dd or a time the way read prints it."
}
$sinceAt = $null; $untilAt = $null
if ($Since) { $sinceAt = (Get-Span $Since 'Since')[0] }
if ($Until) { $untilAt = (Get-Span $Until 'Until')[1] }
if ($sinceAt -and $untilAt -and $sinceAt -ge $untilAt) { Fail '-Since is not before -Until.' }
$pattern = $null
if ($Grep) { try { $pattern = [regex]::new($Grep, 'IgnoreCase') } catch { Fail "-Grep is not a valid regular expression: $($_.Exception.InnerException.Message)" } }

# send checks everything it was given before it touches the window.
$imageTypes = '.bmp', '.dib', '.gif', '.jpg', '.jpeg', '.pjpeg', '.png', '.tif', '.tiff', '.ico'
$files = @()
if ($Command -eq 'send') {
  if (-not $Text -and -not $attachPaths.Count) { Fail 'send needs -Text, -Attach, or both.' }
  foreach ($p in $attachPaths) {
    if ($p -notmatch '^([A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)') { Fail "-Attach `"$p`" is not a full path." }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Fail "-Attach `"$p`" is not a file." }
    if ($imageTypes -notcontains [IO.Path]::GetExtension($p).ToLowerInvariant()) { Fail "-Attach `"$p`" is not an image type Phone Link sends: $($imageTypes -join ' ')." }
    $files += (Get-Item -LiteralPath $p).FullName
  }
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$All = [System.Windows.Automation.Condition]::TrueCondition
$CT = [System.Windows.Automation.ControlType]
function Cond($property, $value) { New-Object System.Windows.Automation.PropertyCondition($property, $value) }
function ById([string]$id) { Cond $AE::AutomationIdProperty $id }
function Pattern($element, $pattern) { $element.GetCurrentPattern($pattern::Pattern) }
$itemCond = Cond $AE::ControlTypeProperty $CT::ListItem
$prefix = 'Conversation with '

# Every label carries invisible direction marks around names, dates, and times.
function Clean([string]$s) { if ($null -eq $s) { '' } else { $s -replace '\p{Cf}', '' } }
function Get-Digits([string]$s) { $s -replace '\D', '' }
# Waits for a condition for up to a number of seconds and returns its last result.
function Wait-For([scriptblock]$test, [double]$seconds) {
  $until = (Get-Date).AddSeconds($seconds)
  do { $r = & $test; if ($r) { return $r }; Start-Sleep -Milliseconds 250 } while ((Get-Date) -lt $until)
  & $test
}

function Find-Window { $AE::RootElement.FindFirst($Scope::Children, (Cond $AE::NameProperty 'Phone Link')) }
$win = Find-Window
if (-not $win) {
  Start-Process explorer.exe 'shell:AppsFolder\Microsoft.YourPhone_8wekyb3d8bbwe!App'
  $win = Wait-For { Find-Window } 15
  if (-not $win) { Fail 'the Phone Link window did not open.' }
  Start-Sleep -Seconds 3
}
if (-not ('PhoneTexts.Native' -as [type])) {
  Add-Type -Namespace PhoneTexts -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(System.IntPtr p, EnumProc f, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetWindow(System.IntPtr h, uint cmd);
[DllImport("user32.dll")] public static extern System.IntPtr GetDlgItem(System.IntPtr h, int id);
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")]
public static extern System.IntPtr SendText(System.IntPtr h, uint m, System.IntPtr w, string l, uint flags, uint ms, out System.IntPtr result);
[DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")]
public static extern System.IntPtr ReadText(System.IntPtr h, uint m, System.IntPtr w, System.Text.StringBuilder l, uint flags, uint ms, out System.IntPtr result);
'@
}
$N = [PhoneTexts.Native]
$windowHandle = [System.IntPtr]$win.Current.NativeWindowHandle
$state = (Pattern $win ([System.Windows.Automation.WindowPattern])).Current.WindowVisualState
if ($state -eq [System.Windows.Automation.WindowVisualState]::Minimized) {
  $script:minimizedWindow = $windowHandle
  [void]$N::ShowWindow($windowHandle, 4)
  Start-Sleep -Milliseconds 1500
}
$list = $win.FindFirst($Scope::Descendants, (ById 'CVSListView'))
if (-not $list) { Fail 'the Phone Link window shows no conversation list. Open Messages in Phone Link and run again.' }
$listScroll = Pattern $list ([System.Windows.Automation.ScrollPattern])

function Get-Participants([string]$label) { ((Clean $label).Substring($prefix.Length) -split '\. (Unread messages|Message preview)\.')[0] }

# The list builds only the rows near the view, so it is walked from top to bottom.
function Get-Conversations([string]$stopAt) {
  $found = [ordered]@{}
  $step = [math]::Max(1.0, $listScroll.Current.VerticalViewSize * 0.5)
  $at = 0.0
  while ($true) {
    if ($listScroll.Current.VerticallyScrollable) { $listScroll.SetScrollPercent(-1, [math]::Min(100.0, $at)); Start-Sleep -Milliseconds 350 }
    foreach ($row in $list.FindAll($Scope::Descendants, $itemCond)) {
      $label = Clean $row.Current.Name
      if (-not $label.StartsWith($prefix)) { continue }
      $who = Get-Participants $label
      if (-not $found.Contains($who)) {
        $found[$who] = [pscustomobject]@{ Participants = $who; People = @($who -split ', '); Unread = $label.Contains('. Unread messages.'); At = [math]::Min(100.0, $at) }
      }
    }
    if ($stopAt -and $found.Contains($stopAt)) { return @($found[$stopAt]) }
    if (-not $listScroll.Current.VerticallyScrollable -or $at -ge 100.0) { break }
    $at += $step
  }
  if ($listScroll.Current.VerticallyScrollable) { $listScroll.SetScrollPercent(-1, 0) }
  @($found.Values)
}

# A name with digits also fits the end of a number, from 3 digits for reading and from 7 for sending.
$minDigits = if ($Command -eq 'send') { 7 } else { 3 }
function Test-Person([string]$name, [string]$person) {
  if ($person.IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  $d = Get-Digits $name
  return ($d.Length -ge $minDigits -and (Get-Digits $person).EndsWith($d))
}
function Test-Includes($conversation, [string[]]$names) {
  foreach ($n in $names) { if (-not ($conversation.People | Where-Object { Test-Person $n $_ })) { return $false } }
  return $true
}
# Exactly these people: each name fits a different person, and no one is left over.
function Test-Exactly($conversation, [string[]]$names) {
  $people = @($conversation.People)
  if ($people.Count -ne $names.Count) { return $false }
  function Match([int]$i, [bool[]]$taken) {
    if ($i -ge $names.Count) { return $true }
    for ($j = 0; $j -lt $people.Count; $j++) {
      if (-not $taken[$j] -and (Test-Person $names[$i] $people[$j])) {
        $taken[$j] = $true
        if (Match ($i + 1) $taken) { return $true }
        $taken[$j] = $false
      }
    }
    return $false
  }
  Match 0 (New-Object bool[] $people.Count)
}

# read and send stop walking the list at a conversation named exactly as threads prints it.
$conversations = @(if ($Command -eq 'threads') { Get-Conversations '' } else { Get-Conversations $Conversation.Trim() })
if (-not $conversations.Count) { Fail 'the conversation list is empty. Open Messages in Phone Link and run again.' }

if ($Command -eq 'threads') {
  $shown = $conversations
  if ($withNames.Count) { $shown = @($conversations | Where-Object { Test-Includes $_ $withNames }) }
  foreach ($c in $shown) {
    if ($Json) { [pscustomobject]@{ participants = $c.People; unread = $c.Unread } | ConvertTo-Json -Compress }
    elseif ($c.Unread) { "$($c.Participants)`t(unread)" }
    else { $c.Participants }
  }
  if (-not $Json) { Write-Output "$($shown.Count) of $($conversations.Count) conversations" }
  Restore-Window
  exit 0
}

# The exact participants first, then the one conversation whose people are exactly the names, then for read the one that includes them.
# send never takes a conversation that includes others too, so a name alone never reaches a group.
$names = @(Split-List $Conversation ',' 'the conversation')
$target = @($conversations | Where-Object { $_.Participants -eq $Conversation.Trim() })
if (-not $target.Count) {
  $repeated = @($names | Group-Object | Where-Object { $_.Count -gt 1 })
  if ($repeated.Count) { Fail "`"$($repeated[0].Name)`" is named twice in the conversation." }
  $including = @($conversations | Where-Object { Test-Includes $_ $names })
  $target = @($including | Where-Object { Test-Exactly $_ $names })
  if ($target.Count -ne 1 -and $Command -eq 'read') { $target = $including }
}
if ($target.Count -gt 1) { Fail ("`"$Conversation`" fits $($target.Count) conversations. Pass one as threads prints it:`n  " + (($target | ForEach-Object { $_.Participants }) -join "`n  ")) }
if (-not $target.Count -and $Command -eq 'read') { Fail "no conversation includes `"$Conversation`". Run threads to see them." }
$target = if ($target.Count) { $target[0] } else { $null }

function Open-Conversation($conversation) {
  # When another conversation is open, its messages must be gone from the pane before this one counts as open.
  $already = [bool](Get-ConversationInput $conversation)
  $old = @{}
  if (-not $already) { $p = Get-MessagePane; if ($p) { foreach ($item in $p.FindAll($Scope::Children, $All)) { $old[(Clean $item.Current.Name)] = $true } } }
  if ($listScroll.Current.VerticallyScrollable) { $listScroll.SetScrollPercent(-1, $conversation.At); Start-Sleep -Milliseconds 400 }
  $row = $list.FindAll($Scope::Descendants, $itemCond) | Where-Object { $label = Clean $_.Current.Name; $label.StartsWith($prefix) -and (Get-Participants $label) -eq $conversation.Participants } | Select-Object -First 1
  if (-not $row) { Fail 'the conversation moved in the list while it was being found. Run again.' }
  (Pattern $row ([System.Windows.Automation.SelectionItemPattern])).Select()
  if ($listScroll.Current.VerticallyScrollable) { $listScroll.SetScrollPercent(-1, 0) }
  # The message box is labeled "Send a message from <SIM>, Conversation with <participants>.", then any attachments,
  # so it tells when the window has switched, before anything is read from or typed into the conversation.
  $box = Wait-For { Get-ConversationInput $conversation } 8
  if (-not $box) { Fail 'the conversation did not open in Phone Link. Run again.' }
  if ($old.Count) {
    $switched = Wait-For {
      $p = Get-MessagePane
      if ($p) { $labels = @($p.FindAll($Scope::Children, $All) | ForEach-Object { Clean $_.Current.Name } | Where-Object { $_.StartsWith('Message from ') }); if ($labels.Count -and -not @($labels | Where-Object { $old.ContainsKey($_) }).Count) { $true } }
    } 8
    if (-not $switched) { Fail 'the conversation did not open in Phone Link. Run again.' }
  }
  $box
}
function Get-Input { $win.FindFirst($Scope::Descendants, (ById 'InputTextBox')) }
# The label is "Send a message from <SIM>, Conversation with <participants>." and, once images are staged,
# ", <n> attachment(s) added , <file names>". Only the conversation part is compared, never the file names.
$inputLabelRx = [regex]'^Send a message from [^,]*, (?<who>(?:New c|C)onversation with .*?\.)(?:, \d+ attachments? added\b.*)?$'
function Get-InputConversation($i) { $m = $inputLabelRx.Match((Clean $i.Current.Name)); if ($m.Success) { $m.Groups['who'].Value } }
function Get-ConversationInput($conversation) {
  $i = Get-Input
  if ($i -and (Get-InputConversation $i) -eq "Conversation with $($conversation.Participants).") { $i }
}

$messageCond = New-Object System.Windows.Automation.AndCondition((Cond $AE::ControlTypeProperty $CT::List), (Cond $AE::NameProperty 'Messages'))
function Get-MessagePane { $p = $win.FindFirst($Scope::Descendants, $messageCond); if ($p -and $p.FindFirst($Scope::Children, $All)) { $p } }

$bodyCond = ById 'MessageBody'
$imageCond = ById 'ImagePresenter'
$attachCond = ById 'AttachmentsScrollViewer'
$whenRx = [regex]::new('(?<when>(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{1,2}, \d{4} \d{1,2}:\d{2} [AP]M)(?: - (?<status>[^.]*))?\.', 'RightToLeft')
$shortRx = [regex]::new('(?<day>\d{1,2}/\d{1,2}/\d{4}) at (?<time>\d{1,2}:\d{2} [AP]M)\.', 'RightToLeft')

# A row's label is "Message from <sender>. <text>. <date> <time> - <status>. <short date>." with the short date sometimes unfilled.
function Read-Row($item, [string]$label) {
  $body = ''
  $b = $item.FindFirst($Scope::Descendants, $bodyCond)
  if ($b) { $body = (Clean $b.Current.Name).Trim() }
  $rest = $label.Substring('Message from '.Length)
  $cut = -1
  if ($body) { $cut = $rest.IndexOf('. ' + $body.Split("`n")[0].Trim()) }
  if ($cut -lt 0) { $cut = $rest.IndexOf('. ') }
  $who = if ($cut -ge 0) { $rest.Substring(0, $cut) } else { $rest }
  $time = $null; $status = ''
  $m = $whenRx.Match($label)
  if ($m.Success) { $time = [datetime]::ParseExact($m.Groups['when'].Value, 'MMM d, yyyy h:mm tt', $us); $status = $m.Groups['status'].Value }
  else { $s = $shortRx.Match($label); if ($s.Success) { $time = [datetime]::ParseExact("$($s.Groups['day'].Value) $($s.Groups['time'].Value)", 'M/d/yyyy h:mm tt', $us) } }
  $attachments = @()
  $box = $item.FindFirst($Scope::Descendants, $attachCond)
  if ($box) {
    foreach ($a in $box.FindAll($Scope::Descendants, $itemCond)) {
      if ($a.FindFirst($Scope::Subtree, $imageCond)) { $attachments += 'image' } else { $attachments += 'attachment' }
    }
  }
  $own = $who -eq 'you'
  $unsent = $own -and $status -and -not $status.StartsWith('Sent')
  $sender = if ($unsent) { 'me (not sent)' } elseif ($own) { 'me' } else { $who }
  [pscustomobject]@{ Time = $time; From = $sender; Own = $own; Unsent = $unsent; Status = $status; Text = $body; Attachments = $attachments }
}
function Get-Label($m) {
  $parts = @()
  if ($m.Text) { $parts += $m.Text }
  if ($m.Attachments.Count) { $parts += '[' + ($m.Attachments -join ', ') + ']' }
  if ($parts.Count) { $parts -join ' ' } else { '[no text]' }
}
function Format-Time($t) { if ($t) { $t.ToString('ddd yyyy-MM-dd hh:mmtt', $us) } else { 'no date' } }
function Format-Line($m) { "$(Format-Time $m.Time) | $($m.From): " + ((Get-Label $m) -replace "\r?\n", "`n    ") }

if ($Command -eq 'send') {
  function Get-Staged { $h = $win.FindFirst($Scope::Descendants, (ById 'ImagePreviewScrollHost')); if ($h) { @($h.FindAll($Scope::Descendants, (Cond $AE::ControlTypeProperty $CT::Button)) | Where-Object { $_.Current.Name -like 'Remove image*' }) } else { @() } }
  # Phone Link's file picker is a standard Open dialog owned by its window, answered with window messages, with no keystrokes.
  $WM_SETTEXT = 0x000C; $WM_GETTEXT = 0x000D; $WM_COMMAND = 0x0111; $IDOK = 1; $IDCANCEL = 2; $GW_OWNER = 4
  function Find-Picker {
    $script:picker = [System.IntPtr]::Zero
    [void]$N::EnumWindows({ param($h, $l)
        $c = New-Object System.Text.StringBuilder 64; [void]$N::GetClassName($h, $c, 64)
        if ($c.ToString() -eq '#32770' -and $N::IsWindowVisible($h) -and $N::GetWindow($h, $GW_OWNER) -eq $windowHandle) { $script:picker = $h }
        $true }, [System.IntPtr]::Zero)
    if ($script:picker -ne [System.IntPtr]::Zero) { $script:picker }
  }
  # On a failure after typing, the message box is emptied so nothing half-made is left for a later Send.
  # Returns whether the box ended up empty.
  # It touches only the conversation it typed into, and never throws.
  function Clear-Compose {
    $script:composed = $false
    try {
      $dialog = Find-Picker
      if ($dialog) {
        [void]$N::PostMessage($dialog, $WM_COMMAND, [System.IntPtr]$IDCANCEL, [System.IntPtr]::Zero)
        if (-not (Wait-For { -not $N::IsWindow($dialog) } 10)) { return $false }
        Start-Sleep -Milliseconds 500
      }
      if (-not (Test-Recipients)) { return $false }
      for ($k = 0; $k -lt 20; $k++) {
        $staged = @(Get-Staged)
        if (-not $staged.Count) { break }
        (Pattern $staged[0] ([System.Windows.Automation.InvokePattern])).Invoke()
        Start-Sleep -Milliseconds 300
      }
      $i = Get-Input
      if (-not $i -or -not (Test-Recipients)) { return $false }
      (Pattern $i ([System.Windows.Automation.ValuePattern])).SetValue('')
      Start-Sleep -Milliseconds 300
      $i = Get-Input
      return [bool]($i -and -not (Pattern $i ([System.Windows.Automation.ValuePattern])).Current.Value -and -not @(Get-Staged).Count)
    } catch { return $false }
  }
  # Who the message goes to, checked again right before Send.
  function Test-Recipients {
    if ($target) { return [bool](Get-ConversationInput $target) }
    # A new message to people who already have a conversation turns into that conversation.
    if (Get-ConversationInput ([pscustomobject]@{ Participants = $script:recipients -join ', ' })) { return $true }
    $now = @(Get-Chips)
    $now.Count -and ($now -join "`n") -eq ($script:recipients -join "`n")
  }
  function Get-Chips {
    $c = $win.FindFirst($Scope::Descendants, (ById 'ContactsScrollViewer'))
    if ($c) { $c.FindAll($Scope::Descendants, (ById 'RemoveButton')) | ForEach-Object { (Clean $_.Current.Name) -replace '^Remove recipient ', '' -replace ' - \d+ of \d+$', '' } }
  }
  # A new message that fails while its recipients go in loses the recipients it was given.
  function Remove-Chips {
    for ($k = 0; $k -lt 20; $k++) {
      $c = $win.FindFirst($Scope::Descendants, (ById 'ContactsScrollViewer'))
      $b = if ($c) { $c.FindFirst($Scope::Descendants, (ById 'RemoveButton')) }
      if (-not $b) { break }
      (Pattern $b ([System.Windows.Automation.InvokePattern])).Invoke(); Start-Sleep -Milliseconds 300
    }
  }

  if ($target) {
    $box = Open-Conversation $target
    $heading = $target.Participants
  } else {
    # No conversation has these people yet, so a new message names each one in the To box.
    (Pattern ($win.FindFirst($Scope::Descendants, (ById 'NewMessageButton'))) ([System.Windows.Automation.InvokePattern])).Invoke()
    $suggestBox = Wait-For { $win.FindFirst($Scope::Descendants, (ById 'ContactSuggestionsBox')) } 5
    if (-not $suggestBox) { Fail 'Phone Link did not open a new message. Nothing was sent. Run again.' }
    $to = $suggestBox.FindFirst($Scope::Descendants, (Cond $AE::ControlTypeProperty $CT::Edit))
    if (@(Get-Chips).Count) { Fail "Phone Link's new message already has recipients. Clear it in Phone Link first. Nothing was sent." }
    $script:addingChips = $true
    $chosen = 0
    foreach ($name in $names) {
      (Pattern $to ([System.Windows.Automation.ValuePattern])).SetValue($name)
      # The list fills in as Phone Link searches, so it is used once two reads agree.
      $script:lastNames = ''
      $items = @(Wait-For {
          $l = $win.FindFirst($Scope::Descendants, (ById 'SuggestionsList'))
          if ($l) {
            $f = @($l.FindAll($Scope::Children, $itemCond))
            $names_ = (@($f | ForEach-Object { Clean $_.Current.Name }) -join "`n")
            if ($f.Count -and $names_ -eq $script:lastNames) { , $f } else { $script:lastNames = $names_; Start-Sleep -Milliseconds 400 }
          }
        } 6)
      # A contact suggestion shows the contact's name and then its number with the number's kind.
      $contacts = @(foreach ($item in $items) {
          $parts = @($item.FindAll($Scope::Descendants, (Cond $AE::ControlTypeProperty $CT::Text)) | ForEach-Object { Clean $_.Current.Name })
          if ($parts.Count -ge 2 -and (Get-Digits $parts[1]).Length -ge 7) { [pscustomobject]@{ Item = $item; Name = $parts[0]; Number = $parts[1] } }
        })
      $digits = Get-Digits $name
      $isNumber = $digits.Length -ge 7 -and $digits.Length -eq ($name -replace '[\s()+.-]', '').Length
      $fits = @(if ($isNumber) {
          $contacts | Where-Object { (Get-Digits $_.Number).EndsWith($digits) -or $digits.EndsWith((Get-Digits $_.Number)) }
        } else {
          $contacts | Where-Object { $_.Name.IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
        })
      $expect = $null
      if ($fits.Count -eq 1) { $expect = $fits[0].Name; (Pattern $fits[0].Item ([System.Windows.Automation.InvokePattern])).Invoke() }
      elseif ($fits.Count -gt 1) {
        Fail ("`"$name`" fits $($fits.Count) contacts. Pass the number instead:`n  " + (($fits | ForEach-Object { "$($_.Name), $($_.Number)" }) -join "`n  "))
      } elseif ($isNumber) {
        (Pattern $suggestBox ([System.Windows.Automation.InvokePattern])).Invoke()
      } else { Fail "no conversation or contact matches `"$name`". Run threads to see the conversations, or pass a phone number." }
      $chosen++
      # Each step adds exactly one chip, the one asked for, and leaves the earlier ones as they were.
      $now = @(Wait-For { $r = @(Get-Chips); if ($r.Count -ge $chosen) { , $r } } 4)
      if ($now.Count -ne $chosen) { Fail "Phone Link did not take `"$name`" as the only new recipient." }
      if ($chosen -gt 1 -and (($now[0..($chosen - 2)] -join "`n") -ne ($script:recipients -join "`n"))) { Fail 'the recipients changed in Phone Link while they were being added. Nothing was sent.' }
      $added = $now[-1]
      $tail = $digits.Substring([math]::Max(0, $digits.Length - 10))
      $right = if ($expect) { $added -eq $expect } else { $isNumber -and (Get-Digits $added).EndsWith($tail) }
      if (-not $right) {
        Fail "Phone Link took `"$added`" as the recipient for `"$name`"."
      }
      $script:recipients = $now
    }
    $script:addingChips = $false
    $box = Get-Input
    $heading = $script:recipients -join ', '
  }

  $boxValue = Pattern $box ([System.Windows.Automation.ValuePattern])
  if ($boxValue.Current.Value -or @(Get-Staged).Count) { Fail "Phone Link's message box for this conversation already holds an unsent message. Send or clear it in Phone Link first." }
  $script:composed = $true

  # Images go in before the text.
  $count = 0
  foreach ($file in $files) {
    $attachButton = $win.FindFirst($Scope::Descendants, (ById 'AttachImageButton'))
    if (-not (Wait-For { $win.FindFirst($Scope::Descendants, (ById 'BrowseButton')) } 1)) { (Pattern $attachButton ([System.Windows.Automation.TogglePattern])).Toggle() }
    $browse = Wait-For { $win.FindFirst($Scope::Descendants, (ById 'BrowseButton')) } 5
    if (-not $browse) { Fail "Phone Link's attach button showed no 'Browse this PC'. Nothing was sent." }
    (Pattern $browse ([System.Windows.Automation.InvokePattern])).Invoke()
    $dialog = Wait-For { Find-Picker } 15
    if (-not $dialog) { Fail 'the file picker did not open. Nothing was sent. Run again.' }
    $combo = $N::GetDlgItem($dialog, 1148)
    $script:edit = [System.IntPtr]::Zero
    if ($combo -ne [System.IntPtr]::Zero) {
      [void]$N::EnumChildWindows($combo, { param($c, $l) $k = New-Object System.Text.StringBuilder 16; [void]$N::GetClassName($c, $k, 16); if ($k.ToString() -eq 'Edit') { $script:edit = $c; return $false }; $true }, [System.IntPtr]::Zero)
    }
    $r = [System.IntPtr]::Zero
    $read = New-Object System.Text.StringBuilder 2048
    if ($script:edit -eq [System.IntPtr]::Zero -or
        $N::SendText($script:edit, $WM_SETTEXT, [System.IntPtr]::Zero, $file, 2, 2000, [ref]$r) -eq [System.IntPtr]::Zero -or
        $N::ReadText($script:edit, $WM_GETTEXT, [System.IntPtr]2048, $read, 2, 2000, [ref]$r) -eq [System.IntPtr]::Zero -or $read.ToString() -ne $file) {
      [void]$N::PostMessage($dialog, $WM_COMMAND, [System.IntPtr]$IDCANCEL, [System.IntPtr]::Zero)
      Fail 'the file picker did not take the path. Nothing was sent. Run again.'
    }
    [void]$N::PostMessage($dialog, $WM_COMMAND, [System.IntPtr]$IDOK, [System.IntPtr]::Zero)
    # A file on the phone is downloaded when the picker opens it, which can take a while.
    if (-not (Wait-For { -not $N::IsWindow($dialog) } 60)) {
      [void]$N::PostMessage($dialog, $WM_COMMAND, [System.IntPtr]$IDCANCEL, [System.IntPtr]::Zero)
      Fail "the file picker did not accept `"$file`". Nothing was sent."
    }
    $count++
    if (-not (Wait-For { @(Get-Staged).Count -ge $count } 15)) { Fail "Phone Link did not attach `"$file`". Nothing was sent." }
  }

  if (-not (Test-Recipients)) { Fail 'the conversation changed in Phone Link while the message was being made. Nothing was sent.' }
  if ($Text) {
    $boxValue.SetValue($Text)
    $typed = Wait-For { ($boxValue.Current.Value -replace '\r\n?', "`n") -eq ($Text -replace '\r\n?', "`n") } 3
    if (-not $typed) { Fail "Phone Link's message box did not take the text. Nothing was sent." }
  }

  if ($Draft) {
    $script:composed = $false
    $script:minimizedWindow = $null
    Start-Process explorer.exe 'shell:AppsFolder\Microsoft.YourPhone_8wekyb3d8bbwe!App'
    Write-Output "drafted for $heading, not sent. It waits in Phone Link's message box for the user to press Send."
    exit 0
  }

  # Messages already showing before Send, so the new one is told apart from older ones with the same text.
  $pane = Get-MessagePane
  $before = @{}
  if ($pane) { foreach ($item in $pane.FindAll($Scope::Children, $All)) { $before[(Clean $item.Current.Name)] = $true } }
  $sendButton = $win.FindFirst($Scope::Descendants, (ById 'SendMessageButton'))
  if (-not $sendButton.Current.IsEnabled) { Fail "Phone Link's Send button is not available for this message. Nothing was sent." }
  if (-not (Test-Recipients)) { Fail 'the conversation changed in Phone Link before Send. Nothing was sent.' }
  $sentAt = Get-Minute (Get-Date)
  $script:check = "Check with read `"$heading`" -From me -Last 1 before sending it again."
  $script:sendPressed = $true
  (Pattern $sendButton ([System.Windows.Automation.InvokePattern])).Invoke()
  $script:composed = $false

  # A new message turns into its conversation on Send, with a new message box, so the box is found again each time.
  $taken = Wait-For {
    if (-not (Find-Window)) { return 'closed' }
    $i = Get-Input
    if ($i -and -not (Pattern $i ([System.Windows.Automation.ValuePattern])).Current.Value -and -not @(Get-Staged).Count) { 'taken' }
  } 15
  if ($taken -eq 'closed') { $script:minimizedWindow = $null; Fail "Phone Link closed while sending, so the message may have gone out. $($script:check)" }
  if (-not $taken) { Fail "Phone Link kept the message in its box after Send. Look at Phone Link. $($script:check)" }

  # The conversation shows the message once Phone Link has handed it to the phone.
  $wantText = ($Text -replace '\r\n?', "`n").Trim()
  $script:hit = $null
  $shownRow = Wait-For {
    $p = Get-MessagePane
    if ($p) {
      $ps = Pattern $p ([System.Windows.Automation.ScrollPattern])
      if ($ps.Current.VerticallyScrollable) { $ps.SetScrollPercent(-1, 100) }
      $hit = $null
      foreach ($item in $p.FindAll($Scope::Children, $All)) {
        $label = Clean $item.Current.Name
        if (-not $label.StartsWith('Message from you') -or $before.ContainsKey($label)) { continue }
        $m = Read-Row $item $label
        if ($m.Time -and $m.Time -lt $sentAt) { continue }
        if (($m.Text -replace '\r\n?', "`n").Trim() -eq $wantText -and ($m.Attachments.Count -gt 0) -eq ($files.Count -gt 0)) { $hit = $m }
      }
      if ($hit) { $script:hit = $hit }
      if ($hit -and $hit.Status.StartsWith('Sent')) { $hit }
    }
  } 30
  if (-not $shownRow -and $script:hit.Status) { Fail "Phone Link shows the message as `"$($script:hit.Status)`", not sent, though it may still go out. $($script:check)" }
  if (-not $shownRow) { Fail "Phone Link took the message but has not shown it as sent yet. Wait a minute, then $($script:check.Substring(0,1).ToLower() + $script:check.Substring(1))" }
  Write-Output "sent to $heading"
  Write-Output (Format-Line $shownRow)
  Restore-Window
  exit 0
}

[void](Open-Conversation $target)
$pane = Wait-For { Get-MessagePane } 8
if (-not $pane) { Fail 'the conversation opened but showed no messages. Wait for Phone Link to load it and run again.' }
Start-Sleep -Milliseconds 800
$paneScroll = Pattern $pane ([System.Windows.Automation.ScrollPattern])

$seen = @{}
$rows = New-Object System.Collections.Generic.List[object]
# The walk moves up, so the rows each step finds sit above every row found before, and go in front of them.
function Harvest {
  $new = New-Object System.Collections.Generic.List[object]
  foreach ($item in $pane.FindAll($Scope::Children, $All)) {
    $label = Clean $item.Current.Name
    if (-not $label.StartsWith('Message from ') -or $seen.ContainsKey($label)) { continue }
    $seen[$label] = $true
    $new.Add((Read-Row $item $label))
  }
  $rows.InsertRange(0, $new)
}
function Get-Oldest { $t = @($rows | Where-Object { $_.Time } | ForEach-Object { $_.Time } | Sort-Object); if ($t.Count) { $t[0] } else { $null } }

# The pane builds only the rows near the view, so it is walked from the newest message up, stopping once the bound or the count is reached.
$onlyCount = $Last -gt 0 -and -not $fromNames.Count -and -not $pattern -and -not $untilAt
$reachedTop = $true
if ($paneScroll.Current.VerticallyScrollable) {
  $reachedTop = $false
  $step = [math]::Max(0.3, $paneScroll.Current.VerticalViewSize * 0.8)
  $at = 100.0
  while ($true) {
    $paneScroll.SetScrollPercent(-1, [math]::Max(0.0, $at)); Start-Sleep -Milliseconds 150
    Harvest
    $oldest = Get-Oldest
    if ($sinceAt -and $oldest -and $oldest -lt $sinceAt) { break }
    if ($onlyCount -and -not $sinceAt -and $rows.Count -gt $Last) { break }
    if ($at -le 0) {
      Start-Sleep -Milliseconds 1500
      $before = $rows.Count; Harvest
      if ($rows.Count -eq $before) { $reachedTop = $true; break }
    }
    $at -= $step
  }
  $paneScroll.SetScrollPercent(-1, 100)
} else { Harvest }

# Sorted by time, keeping the pane's order within a minute.
for ($k = 0; $k -lt $rows.Count; $k++) { $rows[$k] | Add-Member -NotePropertyName Order -NotePropertyValue $k }
$messages = @($rows | Sort-Object @{ Expression = { if ($_.Time) { $_.Time } else { [datetime]::MaxValue } } }, Order)
$inBounds = @($messages | Where-Object { (-not $sinceAt -or ($_.Time -and $_.Time -ge $sinceAt)) -and (-not $untilAt -or ($_.Time -and $_.Time -lt $untilAt)) })

function Test-Sender($m) {
  foreach ($w in $fromNames) {
    if ($w -eq 'me') { if ($m.Own) { return $true } }
    elseif ($w -eq 'me (not sent)') { if ($m.Unsent) { return $true } }
    elseif (-not $m.Own -and (Test-Person $w $m.From)) { return $true }
  }
  return $false
}
foreach ($w in $fromNames) {
  if ($w -in 'me', 'me (not sent)') { continue }
  $known = @($target.People) + @($messages | Where-Object { -not $_.Own } | ForEach-Object { $_.From })
  if (-not ($known | Where-Object { Test-Person $w $_ })) { [Console]::Error.WriteLine("note: no one in this conversation matches `"$w`".") }
}
$passing = @($inBounds | Where-Object { (-not $fromNames.Count -or (Test-Sender $_)) -and (-not $pattern -or $pattern.IsMatch((Get-Label $_))) })
$shown = @(if ($Last -gt 0 -and $passing.Count -gt $Last) { $passing[($passing.Count - $Last)..($passing.Count - 1)] } else { $passing })

if (-not $Json) { Write-Output "conversation: $($target.Participants)" }
foreach ($m in $shown) {
  if ($Json) {
    $iso = if ($m.Time) { ([datetimeoffset]$m.Time).ToString('yyyy-MM-ddTHH:mm:sszzz', $us) } else { $null }
    [pscustomobject]@{ time = $iso; from = $m.From; text = $m.Text; attachments = @($m.Attachments) } | ConvertTo-Json -Compress
  } else { Format-Line $m }
}
if (-not $Json) {
  if (-not $reachedTop -and -not $sinceAt) { Write-Output "the newest $($shown.Count) messages shown" }
  else {
    $trimmed = if ($shown.Count -lt $passing.Count -and $passing.Count -lt $inBounds.Count) { ", the newest of $($passing.Count) that match" } else { '' }
    Write-Output "$($shown.Count) of $($inBounds.Count) messages shown$trimmed"
  }
}
$oldest = Get-Oldest
if ($oldest -and $reachedTop -and (-not $sinceAt -or $sinceAt -lt $oldest)) {
  [Console]::Error.WriteLine("note: the window holds this conversation from $(Format-Time $oldest) on. Anything older is only on the phone.")
}
Restore-Window
