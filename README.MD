# Discogs State Management

This repository uses a declarative, Git-based workflow to manage a Discogs record collection.

Instead of manually clicking buttons on the Discogs website, you manage a single JSON file (`my_collection.json`) that represents your desired state. You push changes to this file, and the scripts handle the API interactions to make your Discogs collection match your file.

## The Concept

This project is built on the idea of **declarative state**. The `my_collection.json` file is the "Single Source of Truth."

- **If a record is in the file:** It gets added to Discogs.
- **If a record is NOT in the file:** It gets deleted from Discogs.
- **If the file is empty:** Your Discogs collection is wiped clean.

## Repo Structure

```text
├── .gitignore                # Ignores sensitive config files
├── config.json               # (Local only) Your API credentials
├── barcodes.json             # Input file for bulk adding via barcode
├── my_collection.json        # Single Source of Truth (Desired State)
├── import-barcodes.ps1       # Script to convert barcodes -> IDs in state file
├── sync-collection.ps1       # The main engine: Syncs state file to Discogs
└── README.md                 # Project documentation
```

````

##  Setup

1.  **Clone the Repo:**

    ```bash
    git clone [https://github.com/YOUR_USERNAME/discogs-state-mgmt.git](https://github.com/YOUR_USERNAME/discogs-state-mgmt.git)
    cd discogs-state-mgmt
    ```

2.  **Create `config.json`:**
    Create this file in the root directory. **Do not commit this file.**

    ```json
    {
      "username": "Your_Discogs_Username",
      "token": "Your_Personal_Access_Token"
    }
    ```

## Workflow

### Option A: Bulk Add via Barcodes (The "Inbox" Method)

Use this when you have a stack of records to add.

1.  **Scan Barcodes:** Open `barcodes.json` and add the UPC/EAN codes from your record sleeves.

    ```json
    ["602448519122", "889854390310"]
    ```

2.  **Run Import:**

    ```powershell
    .\Import-Barcodes.ps1
    ```

    - _This searches Discogs for each barcode._
    - _It adds new finds to `my_collection.json` (it will **not** duplicate existing items)._

3.  **Sync:**

    ```powershell
    .\Sync-Collection.ps1
    ```

    - _This pushes the new records to your Discogs profile._

### Option B: Manual Management

Use this to delete items or add specific releases without a barcode.

1.  **Edit `my_collection.json`:**
    - **To Delete:** Simply remove the record block from the JSON array.
    - **To Add:** Manually add a block with the Release ID and Artist (for validation).
    <!-- end list -->
    ```json
    {
      "records": [
        {
          "id": 12345,
          "artist": "Pink Floyd",
          "notes": "Original Pressing"
        }
      ]
    }
    ```
2.  **Sync:**
    ```powershell
    .\Sync-Collection.ps1
    ```
````
