const express = require('express');
const router = express.Router();
const friendsController = require('../controllers/friendsController');
const authMiddleware = require('../middleware/auth');

router.post('/request', authMiddleware, friendsController.sendRequest);
router.post('/accept', authMiddleware, friendsController.acceptRequest);
router.post('/remove', authMiddleware, friendsController.removeFriend);
router.get('/:user_id', authMiddleware, friendsController.getFriends);

module.exports = router;
