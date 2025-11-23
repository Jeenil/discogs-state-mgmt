# Discogs State Management

This repository uses a declarative, Git-based workflow to manage a Discogs record collection.

Instead of manually clicking buttons on the Discogs website, you manage a single JSON file (`my_collection.json`) that represents your desired state. You push changes to this file, and the scripts handle the API interactions to make your Discogs collection match your file.

## The Concept

This project is built on the idea of **declarative state**. The `my_collection.json` file is the "Single Source of Truth."

- **If a record is in the file:** It gets added to Discogs.
- **If a record is NOT in the file:** It gets deleted from Discogs.
- **If the file is empty:** Your Discogs collection is wiped clean.

## 📂 Repo Structure

```text
├── .gitignore                # Ignores sensitive config files
├── config.json               # (Local only) Your API credentials
├── barcodes.json             # Input file for bulk adding via barcode
├── my_collection.json        # Single Source of Truth (Desired State)
├── import-barcodes.ps1       # Script to convert barcodes -> IDs in state file
├── sync-collection.ps1       # The main engine: Syncs state file to Discogs
└── README.md                 # Project documentation
```

## Setup

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

## Automation (CI/CD)

This project is configured with GitHub Actions. When you push changes to `my_collection.json` to the `main` branch, a workflow automatically runs `Sync-Collection.ps1` to update your Discogs account.

- **Trigger:** Push to `main` (specifically `my_collection.json`).
- **Secrets Required:** `DISCOGS_USERNAME`, `DISCOGS_TOKEN`.

## Technical Concepts: Why HashMaps?

To make the sync script fast and efficient, we use specific data structures.

| Structure           | Analogy          | Why we use it                                                                                                                                                               |
| :------------------ | :--------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Array** `[]`      | **A Bookshelf**  | Good for simple lists we need to loop through one by one (like the list of items to Delete).                                                                                |
| **HashTable** `@{}` | **A Coat Check** | Good for instant lookups. We use this to map **Release IDs** (ISBNs) to **Instance IDs** (Barcodes) so the script knows exactly which copy to delete.                       |
| **HashSet**         | **A VIP List**   | Optimized purely for checking _"Is this person on the list?"_ We use this to compare your Local File against Discogs instantly, without scanning the whole list every time. |

---

## Important Note on Deletions

Discogs requires an **Instance ID** (specific copy ID) to delete a record, but we only track **Release IDs** (general album ID).

The script handles this automatically:

1.  It fetches your current collection to find the Instance ID map.
2.  It compares it against your `my_collection.json`.
3.  It performs the deletion using the mapped Instance ID.

_If you see a "Ghost Record" error, it means you have a corrupted item in your Discogs collection that must be deleted manually on the website._
