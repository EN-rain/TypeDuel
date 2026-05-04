const express = require('express');
const router = express.Router();
const chatController = require('../controllers/chatController');
const authMiddleware = require('../middleware/auth');

router.post('/send', authMiddleware, chatController.sendMessage);
router.get('/messages', authMiddleware, chatController.getMessages);
router.post('/mark-read', authMiddleware, chatController.markRead);

module.exports = router;
