# AI Short Drama Studio · Stepwise Variant

This is an independent stepwise variant of the short-drama workflow app.

It does not overwrite the original `ai-shortdrama-studio-app` project. The UI is organized as a guided workflow:

1. Script
2. Episode script
3. Storyboard script
4. Art assets

Each step runs independently. After a step finishes, the left chat panel reports what was completed and shows a summary table. The fixed action bar then offers:

- Continue to next step
- Modify this step
- Rerun this step
- View raw data

## Admin Settings

The settings button is hidden by default. Open the deployed URL with:

```text
?admin=1
```

to show the API settings button in the current browser. Use:

```text
?admin=0
```

to hide it again.

For teammates, prefer Vercel environment variables:

- `OPENAI_API_KEY`
- `OPENAI_BASE_URL`

The safest local sync path is file based:

```powershell
copy .\scripts\OPENAI_API_KEY.local.txt.example .\scripts\OPENAI_API_KEY.local.txt
notepad .\scripts\OPENAI_API_KEY.local.txt
.\scripts\sync-key-from-file.cmd
```

`OPENAI_API_KEY.local.txt` and sync logs are ignored by Git.
