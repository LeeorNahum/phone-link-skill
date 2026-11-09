<#
.SYNOPSIS
Reads texts from the Phone Link window through Windows UI Automation, read-only.

.DESCRIPTION
For texts newer than the database copy holds. Opens Phone Link if no window is found.
-List prints the participants of each conversation in the window's list, newest first,
without message text. -Read selects the first conversation whose participants contain
the given text and prints the messages the window has loaded, oldest first. It never
types, sends, or clicks.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File phone-window.ps1 -List
powershell -NoProfile -ExecutionPolicy Bypass -File phone-window.ps1 -Read "Alex"
#>
param(
  [switch]$List,
  [string]$Read
)

$ErrorActionPreference = 'Stop'
if (-not $List -and -not $Read) { Write-Output 'error: pass -List or -Read "<participant>".'; exit 1 }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$nameCond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Phone Link')
$itemCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)

function Find-Window {
  $AE::RootElement.FindFirst($Scope::Children, $nameCond)
}

$win = Find-Window
if (-not $win) {
  Start-Process explorer.exe 'shell:AppsFolder\Microsoft.YourPhone_8wekyb3d8bbwe!App'
  for ($i = 0; $i -lt 20 -and -not $win; $i++) { Start-Sleep -Milliseconds 500; $win = Find-Window }
  if (-not $win) { Write-Output 'error: the Phone Link window did not open.'; exit 1 }
  Start-Sleep -Seconds 3
}

$prefix = 'Conversation with '
$conversations = @($win.FindAll($Scope::Descendants, $itemCond) | Where-Object { $_.Current.Name.StartsWith($prefix) })
if (-not $conversations.Count) { Write-Output 'error: no conversations in the window. Open Messages in Phone Link and try again.'; exit 1 }

# A list item's name is "Conversation with <participants>. [Unread messages. ]Message preview. <text>".
function Get-Participants($item) {
  ($item.Current.Name.Substring($prefix.Length) -split '\. (Unread messages|Message preview)\.')[0]
}

if ($List) {
  foreach ($c in $conversations) { Get-Participants $c }
  exit 0
}

$target = $conversations | Where-Object { (Get-Participants $_) -like "*$Read*" } | Select-Object -First 1
if (-not $target) { Write-Output "error: no conversation in the window's list has a participant matching `"$Read`". Run -List to see them."; exit 1 }
Write-Output ("conversation: " + (Get-Participants $target))
$target.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
Start-Sleep -Seconds 3

$messages = @($win.FindAll($Scope::Descendants, $itemCond) | Where-Object { -not $_.Current.Name.StartsWith($prefix) })
if (-not $messages.Count) { Write-Output 'note: the conversation shows no messages yet. Wait for Phone Link to load it and run again.'; exit 0 }
# Names carry invisible direction marks around dates and times, which are removed.
foreach ($m in $messages) { $m.Current.Name -replace '[\u200e\u200f]', '' }
Write-Output "note: these are the messages the window has loaded, the most recent ones. Older messages are in the database copy or on the phone."
