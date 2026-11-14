# Phone Link Skill

An Agent Skill that lets an agent running on a Windows computer use the Android phone paired through Microsoft Phone Link: read and send its text and chat messages, pictures included, find its photos and files through File Explorer's mobile device folder, and copy a file onto it.

## How it works

The skill's script works the Phone Link window through Windows UI Automation, programmatically, with no screenshots, keystrokes, or mouse. It lists conversations by participant, prints a conversation's messages with filters for time, sender, and text, and sends or drafts a message with images attached. The phone's photos and files need no script.

## Files

- `SKILL.md` covers when the skill applies, how to run the script, how to send, the phone's folders, the privacy rules, and the gotchas.
- `scripts/phone-texts.ps1` lists conversations, reads messages, and sends them through the Phone Link window.
- `AGENTS.md` is the maintenance contract for editing this skill.

## Running the script

Needs Phone Link paired with an Android phone, and Windows PowerShell.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-root>\scripts\phone-texts.ps1 <command> [options]
```

Run it with `help` for the commands.

## Install

```bash
git submodule add https://github.com/LeeorNahum/phone-link-skill.git .agents/skills/phone-link
```
