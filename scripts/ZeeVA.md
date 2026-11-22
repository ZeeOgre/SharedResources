# ZeeVA Sessions

## Cleaning CK Exports

`ZeeVA_FilterDialogue.ps1` is a standalone, reusable cleaner. Supply the original
per-voice exports; it never modifies them:

```powershell
$exports = @(
    'G:\Exports\dialogueExport_zo_ZEO_NPC_VT_ZeeOgre.txt'
    'G:\Exports\dialogueExport_ChikaVT.txt'
)
.\ZeeVA_FilterDialogue.ps1 -Path $exports
# Optional separate output directory; -Force replaces existing generated files.
.\ZeeVA_FilterDialogue.ps1 -Path $exports -OutputDirectory 'G:\Exports\Clean' -Force
```

For each input it retains only the voice uniquely identified by the filename AND
rows whose `FULL PATH` belongs to `ZeeOgresEnhancedOutposts.esp`. Base-game dialogue
and other voices' rows are excluded. Use `-ModName OtherPlugin.esp` for another mod.
The cleaner writes `<original basename>_filtered.txt` for each voice and
`dialogueExport_ZeeOgresEnhancedOutposts_master.txt` containing the merged filtered
rows. Outputs default to the first input's directory.

All columns, response text, notes, supplied context, UTF-8 encoding and TSV format
are preserved. Voice files retain input order; the master follows the supplied
file order. Duplicate recording IDs are removed case-insensitively within each
voice, including across exports; the same ID in different voices remains separate.
For duplicates with identical response text, the first row's metadata is retained.
Conflicting response text, missing columns, differing export schemas, unknown or
ambiguous filename voices, and an empty voice/plugin result fail before writing
any outputs. Existing generated outputs require `-Force`; generated filtered/master
files must not be supplied as original inputs.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ZeeVA_FilterDialogue.Tests.ps1
```

## Text-Only Recording

Run the standalone text-only recorder:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\ZeeVA_TextOnly.ps1
# Optional: open an export at startup
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\ZeeVA_TextOnly.ps1 -DialoguePath "C:\Scripts\Starfield.tsv"
```

`ZeeVA_TextOnly.ps1` contains the complete implementation and can be copied and
run by itself; it does not load or require `ZeeVA.ps1` or any other helper script.
It still requires Audacity with `mod-script-pipe` enabled, just like ZeeVA. It
provides the same recording controls and export format, but never requires or
imports original WAVs. The existing WAV-based script retains its normal behavior.

- Open Script, or drop one `.txt` / `.tsv` file onto the main window, Open Script
  button/path label, or script window. The import is the same UTF-8, tab-separated
  format, with `FILENAME`, `RESPONSE TEXT` and `VOICE TYPE` columns.
  Both launchers prefer a sibling `<basename>_filtered.txt` (or `_filtered.tsv`)
  over the selected or startup export. If it is absent, the standard export is
  used; if neither exists, a file picker opens. Cancelling does not start a session.
- The voice type named in the export filename (for example,
  `dialogueExport_TestVT.txt`) is selected automatically when it uniquely matches
  a `VOICE TYPE` value, ignoring case. Otherwise a single available voice type is
  selected automatically, or a picker lets you choose when several remain.
  Only rows for that voice type become
  recording lines, in export order, including when other voices appear between
  them. Other voices remain available as preceding/following context, never as
  the current recording line. Explicit `DIALOGUE BEFORE` / `DIALOGUE AFTER` still
  take precedence; fallback context is labeled as export order.
- The output name is the `FILENAME` basename with `.wav`, regardless of whether
  any audio file exists. Invalid names and case-insensitive collisions within the
  selected voice type are rejected before the project starts.
- Previous/Next moves through the selected voice's lines. Record / Stop, Retake,
  Listen Take, Review Take and Save / Accept Take work as usual. Show Script
  replaces Listen Original (including its Ctrl+Shift+F4 shortcut). Acceptance
  advances to the next line without requiring an original track.
- When finished, Export Folder writes accepted takes to
  `<output root>\<selected voice type>\<FILENAME basename>.wav`, with the same
  stereo 44.1 kHz PCM format checks and embedded response-text transcripts.
  Unaccepted lines are skipped; existing outputs require overwrite confirmation.
- Opening a script automatically saves
  `<script basename>_<voice type>.aup3` beside the script, with the usual
  resume/overwrite/cancel handling. The reading window opens before preparation.
  Status shows `Preparing project - 1/23 labels` as the session-data labels are
  written (these counts are metadata chunks, not dialogue lines), followed by
  `Saving Audacity project...`. Initial setup writes those labels only once.
  Stop and Accept also checkpoint recovery data. Session payloads are gzip-compressed
  before splitting into labels, reducing the scripting commands for each save
  without discarding dialogue columns or recovery state.
  In the text-only launcher, the full script/block snapshot is written once.
  Subsequent changes use a separate small `ZeeVA Progress|v2|` label track for
  take selection, acceptance, current line, output path and export receipts.
  Unchanged saves do not rewrite labels. Routine updates show `Saving progress`
  rather than `Preparing project`; changing the script/block data rebuilds the
  full snapshot. Both tracks are required for recovery and count toward the track
  limit. Their checksums bind progress to its matching full snapshot.
  Metadata writes explicitly focus their label track and obtain each new label's
  actual global index before naming it; selection alone does not control where
  Audacity's `AddLabel` writes. An unidentified label stops the save rather than
  renaming an existing region or metadata label.
  Acceptance/export checks allow only the rounding precision of Audacity's
  six-significant-digit JSON times. Export selections are clamped to the reported
  take bounds; empty, disjoint or genuinely out-of-bounds labels still fail.
  More than 40 selected lines use recording
  blocks and `<script basename>_<voice type>_Block<N>.aup3` projects, preserving
  room for retakes within Audacity's scripting track limit.
- Save/Open Project, Scan Project and crash recovery retain their usual behavior.
  The project's session-data labels store only the selected voice's rows for the
  current recording block, plus voice selection, block order and progress,
  so resuming does not require the original text export or a source WAV folder.
  Other voices' rows are not stored in the project. Their fallback export-order
  context is available while the full import is loaded; after resuming, supplied
  before/after context and neighboring saved rows remain available.
  In the standalone text-only launcher, Open Script remains available between
  takes. Select the same export and choose the next block, or select another
  script/voice. Once all selections are confirmed, ZeeVA saves the current
  project (including unaccepted takes), closes it in Audacity, and opens or
  creates the selected project without restarting either application.
  Cancelling a picker leaves the current session intact; selecting the current
  block does nothing. Switching is disabled while recording, busy, disconnected
  or unverified. Keep only one Audacity project window open.
  Use the matching launcher for each project's source mode.
- `ZeeVA_TextOnly.ini` remembers this companion's paths separately from
  `ZeeVA.ini`. Both helpers share Audacity's executable settings and single-client
  protection; do not run them simultaneously.

## Projects

- Open Folder imports a speaker's WAV files and automatically saves
  `foldername.aup3` beside that folder. If it exists, choose Open and Resume,
  Overwrite, or Cancel. Resume opens and scans it automatically. Overwrite imports
  fresh WAVs and preserves the previous project beside it as
  `foldername.backup-<unique ID>.aup3`. Close the existing project before overwriting.
- Audacity's scripting interface can only address tracks 0-100 of a project, and
  every source, take and bookkeeping track counts. Folders with more than 40 WAVs
  are therefore recorded in blocks of 40 files: Open Folder prompts for Block 1,
  2, 3 and so on (preselecting the first block without a project) and saves each
  block as its own `foldername_Block<N>.aup3` beside the folder. Reopening the
  folder and choosing the same block resumes that block's project. Record warns
  when a project reaches 90 tracks and refuses a take that would exceed the cap;
  export the block and continue in the next one.
- Open Project opens an `.aup3` file in an empty Audacity project and scans it.
  To switch sessions in the WAV launcher, save and close the current Audacity
  project and restart ZeeVA. The standalone text-only launcher can switch blocks
  through Open Script as described above.
- Scan Project reads the currently open Audacity project. Older ZeeVA projects
  need their original source folder located once. Acceptance is recovered only
  from an unambiguous filename label within a matching take, not from a recording
  alone. This also recovers newly accepted lines when the bookkeeping snapshot
  predates the crash, without substituting another take for a missing saved
  acceptance. Newly recovered acceptance advances to the first unfinished line.
  A single unaccepted take for the selected line can be recovered as its candidate.
  Multiple unaccepted takes are not guessed between.
- After Audacity recovers a crashed project, ZeeVA finalizes nonempty stereo
  `RECORDING|...` tracks as `TAKE|...` tracks and resumes the latest interrupted
  line. Interrupted audio is available for review, not automatically accepted;
  empty recording targets are ignored. Only audio retained by Audacity can be
  recovered. Save Project after reviewing the recovered state.
- Save Project stores folders, file order, current line, candidate, accepted takes
  and export receipts inside the `.aup3`, using numbered labels on a dedicated
  non-audio track with a short name beginning `ZeeVA Session|v2|`. A checksum
  verifies the complete snapshot. Do not edit or delete this track or its labels.
  Older uncompressed snapshots, including those embedded in a long track name,
  can still be read; the next save replaces them with compressed bounded chunks.
  Use the updated launchers to reopen compressed projects, and the updated
  text-only launcher for projects with a progress track. Commands of 1 KB or more are refused before
  transmission because oversized commands can crash Audacity's scripting module.
- A project already open in Audacity restores automatically when ZeeVA connects,
  if it contains this bookkeeping. Reconnect reconciles it with actual tracks,
  labels and output files. A different project's missing source tracks block resume
  without discarding the previous session.
- `*` in the title means session bookkeeping has unsaved changes. Closing ZeeVA
  offers Save, Discard or Cancel. Stopping a take and accepting a take automatically
  checkpoint bookkeeping, including the next line after acceptance. If ZeeVA knows
  the project path, these checkpoints also save the `.aup3`. For a project attached
  by scanning, bookkeeping is updated inside Audacity without guessing a file path;
  use Save Project to save it to disk. Save Project after export, navigation or
  changing the output folder to preserve those changes.

## Status

- Not recorded: no completed stereo take exists for that line.
- Recorded: a take exists, but has not been accepted.
- Accepted: an explicitly accepted take and its valid region label exist.
- Exported: that accepted take was successfully exported and format-checked by
  ZeeVA. Its saved export receipt must still match the take, region, output folder
  and output WAV checksum. A pre-existing WAV alone never means exported.

Reconnect removes stale acceptance or export status independently. Reaccepting a
take or changing the output folder clears its export status. Manual waveform or
effect edits that retain the same track name and region boundaries cannot be
detected from scripting metadata; re-export after making such edits.

Retake starts recording immediately without confirmation; the previous take's audio
stays in the project. Record / Stop then stops it.
Save / Accept Take accepts the current take and advances to the next WAV, ready for
Listen Original. Accepting the final WAV stays on that line. Save Project only saves
the project and does not advance or accept a take.

Previous/Next preserves acceptance separately for every WAV and restores the
line's explicit unaccepted review choice. Those choices are stored in project
bookkeeping, including choices for noncurrent lines. A line with exactly one
recorded take can be reviewed and accepted after returning to it without recording
again. For multiple takes without a saved choice, Review Take on the main status
bar lets you explicitly choose one, then Listen Take and Save / Accept Take work
normally. Choosing a review take does not accept it.
Only explicit acceptance makes a take eligible for export.

New acceptance labels are placed on the dedicated `ZeeVA Regions` label track,
never on the replaceable session bookkeeping track. Saving preserves filename
labels found on the older bookkeeping track by moving them to `ZeeVA Regions`.
Already-missing regions must be reviewed and explicitly accepted again; missing
labels do not establish that the wrong Audacity project is open by themselves.

## Folders And Settings

Drop one directory onto Open Folder or its path label to import it. Dropping onto
Set Output Folder or its path label sets the output root; exports still go into a
speaker-named subfolder. Drops are unavailable while recording or busy.

`ZeeVA.ini`, beside the script, remembers `OutputRoot`, `LastSource`,
`LastProject` and `DialogueExportPath`. Project bookkeeping takes precedence when resuming. Audacity's
executable path remains in the existing per-user settings.

## Live Script

Script selection runs on startup and when a different source folder is loaded.
ZeeVA derives the game root and voice type from
`<game root>\Data\Sound\<mod.esp>\<voice type>` (also supporting the intervening
`Voice` directory). It prefers `_filtered.txt` / `_filtered.tsv` exports,
including a filtered sibling of a remembered export, then falls back to standard
exports. Within each tier it reuses a valid remembered export, otherwise searches
the game root for filenames containing the voice type. The export's `VOICE TYPE`
column must also contain that voice type. If no unique valid export is found,
including during startup or source-folder changes, a file picker opens at the
game root. Find Script in the center metadata area retries the same discovery.
Cancelling preserves the current script on manual selection; automatic discovery
clears stale dialogue for the previous voice. Invalid exports produce inline
feedback.

The export filename and selection button live in the script window's bottom
metadata area, keeping the upper 75 percent focused on dialogue. Once a script
is loaded, the button becomes Load Script and opens the picker for an explicit
replacement.
`-DialoguePath "path\dialogue.txt"` can supply a preferred export at startup.
Script on the main window reopens the modeless auxiliary window after closing it.
Showing or refreshing it does not activate it or query
Audacity during capture; file selection is unavailable during recording.

The center column follows the active WAV, including navigation and advancement
after acceptance. Matching uses the WAV basename against `FILENAME`, filtered by
the source folder's voice type. A `TOPICINFO` FormID is a fallback only when unique;
`FormID_responseIndex.wav` can identify a specific response. Missing or ambiguous
matches show no dialogue rather than guessing.

The side columns use `DIALOGUE BEFORE` and `DIALOGUE AFTER` when supplied. Otherwise
they show the previous/next WAV in the recording directory, explicitly labeled as
such. Directory order is not necessarily narrative order; branching dialogue can
have multiple preceding or following lines. The current column also shows the
recording ID, topic info, quest, scene and script notes when available.

Export embeds each uniquely matched response text as a UTF-8 RIFF `INFO/ICMT`
comment in the output WAV, replacing existing comments while retaining other
metadata and the PCM audio bytes. This happens before calculating the export
receipt checksum. Sources remain untouched; already exported WAVs need re-export
to gain or update transcripts. The completion message reports transcript coverage.
Metadata-reader support for UTF-8 WAV comments varies, and later audio conversion
tools may discard these comments.

## Tests

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\ZeeVA.Tests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\ZeeVA.Tests.ps1 -SourceFile ZeeVA_TextOnly.ps1
```

Tests use temporary fixtures and mocked Audacity responses, including actual
WinForms control construction. They do not modify a live Audacity project.
