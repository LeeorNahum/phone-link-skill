# Phone Link Skill

An Agent Skill that lets an agent running on a Windows computer use the Android phone paired through Microsoft Phone Link: read its text messages from Phone Link's local database, find its photos and files through File Explorer's mobile device folder, copy a file onto it, and send a text the user approved through the Phone Link window.

## How it works

Phone Link keeps a synced copy of the phone's recent messages in SQLite files on the computer. The skill's script copies those files to a temporary folder, reads the copy, resolves numbers to contact names, and deletes the copy before it exits. It never opens the live files as a database and never sends anything. The phone's photos and files need no script, and sending goes through the Phone Link window. Beyond its reading commands, it runs any read-only SQL against the same copy, and the skill maps the database for those queries.

## Files

- `SKILL.md` covers when the skill applies, how to run the script, the phone's folders, how to send a text, the privacy rules, and the gotchas.
- `scripts/phone-texts.mjs` lists contacts, conversations, messages, and the dates held, and runs read-only queries.
- `scripts/phone-window.ps1` reads conversations from the Phone Link window, for texts newer than the database copy.
- `references/schema.md` maps the database for queries.
- `package.json` exposes the script as a `bin`, so it runs from this repository without being installed.
- `AGENTS.md` is the maintenance contract for editing this skill.

## Running the script

Needs Phone Link paired with an Android phone, and Node.js 22.13 or later.

Without the skill on disk, straight from this repository:

```bash
npx --yes github:LeeorNahum/phone-link-skill <command> [options]
```

With it on disk:

```bash
node <skill-root>/scripts/phone-texts.mjs <command> [options]
```

Run it with `--help` for the commands.

## Install

```bash
git submodule add https://github.com/LeeorNahum/phone-link-skill.git .agents/skills/phone-link
```
