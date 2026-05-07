const fs = require('fs');
const path = require('path');

// Path to feedback JSON file
const FEEDBACK_FILE = path.join(__dirname, '../data/feedback.json');

// Ensure data directory exists
const DATA_DIR = path.join(__dirname, '../data');
if (!fs.existsSync(DATA_DIR)) {
    fs.mkdirSync(DATA_DIR, { recursive: true });
}

// Initialize feedback file if it doesn't exist
if (!fs.existsSync(FEEDBACK_FILE)) {
    fs.writeFileSync(FEEDBACK_FILE, JSON.stringify([], null, 2));
}

// POST /api/feedback
// Body: { user_id, feedback }
const submitFeedback = (req, res) => {
    const { user_id, feedback } = req.body;

    if (!feedback || typeof feedback !== 'string' || feedback.trim().length === 0) {
        return res.status(400).json({ message: 'Feedback text is required' });
    }

    if (feedback.length > 5000) {
        return res.status(400).json({ message: 'Feedback is too long (max 5000 characters)' });
    }

    try {
        // Read existing feedback
        let feedbackData = [];
        if (fs.existsSync(FEEDBACK_FILE)) {
            const fileContent = fs.readFileSync(FEEDBACK_FILE, 'utf8');
            feedbackData = JSON.parse(fileContent);
        }

        // Create new feedback entry
        const feedbackEntry = {
            id: Date.now(), // Use timestamp as ID
            date: new Date().toISOString(),
            user_id: user_id || null,
            feedback: feedback.trim()
        };

        // Add to array
        feedbackData.push(feedbackEntry);

        // Write back to file
        fs.writeFileSync(FEEDBACK_FILE, JSON.stringify(feedbackData, null, 2));

        console.log(`[Feedback] New feedback submitted by user ${user_id || 'anonymous'}`);

        return res.status(200).json({ 
            message: 'Feedback submitted successfully',
            id: feedbackEntry.id
        });

    } catch (error) {
        console.error('[Feedback] Error saving feedback:', error);
        return res.status(500).json({ message: 'Failed to save feedback' });
    }
};

module.exports = { submitFeedback };
