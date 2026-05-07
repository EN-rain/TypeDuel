const express = require('express');
const router = express.Router();
const { submitFeedback } = require('../controllers/feedbackController');

// POST /api/feedback - Submit feedback
router.post('/', submitFeedback);

module.exports = router;
