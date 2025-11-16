# Discogs State Management

This repository uses a declarative, Git-based workflow to manage a Discogs record collection.

You don't run scripts locally. You simply update a JSON file (`my_collection.json`) with the records you want in your collection, push the change, and a GitHub Action handles the rest.

## Plan

Built this project on the idea of **declarative state**. The `my_collection.jsonc` file is my "single source of truth."

## Repo Structure

```
.
├── .github/workflows/
│   └── sync-collection.yml   # The GitHub Action workflow
├── .gitignore                # Ignores config and log files
├── config.json               # (Local only) Your secret credentials
├── my_collection.json        # Your desired state (this is what you edit)
├── my_collection_log.json    # (Bot-managed) Log of all adds/deletes
├── Sync-Collection.ps1       # The main PowerShell sync script
└── README.md                 # This file
```
