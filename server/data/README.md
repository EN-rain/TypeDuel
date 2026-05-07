# Data Directory

This directory contains application data files.

## feedback.json

Stores user feedback submissions in JSON format.

### Structure

Each feedback entry contains:
- `id`: Unique timestamp-based ID
- `date`: ISO 8601 timestamp when feedback was submitted
- `user_id`: User ID (null for anonymous feedback)
- `feedback`: The feedback text (max 5000 characters)

### Example

See `feedback.example.json` for the structure.

### Security

- `feedback.json` is excluded from version control via `.gitignore`
- Feedback is append-only (no deletion via API)
- Maximum length enforced: 5000 characters

### Accessing Feedback

To view feedback, read the file directly:

```bash
cat server/data/feedback.json
```

Or use a JSON viewer:

```bash
cat server/data/feedback.json | jq
```

### Backup

Regularly backup this file as it contains user feedback:

```bash
cp server/data/feedback.json server/data/feedback.backup.$(date +%Y%m%d).json
```
