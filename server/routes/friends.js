const express = require('express');
const router = express.Router();
const friendsController = require('../controllers/friendsController');

router.post('/request', friendsController.sendRequest);
router.post('/accept', friendsController.acceptRequest);
router.post('/remove', friendsController.removeFriend);
router.get('/:user_id', friendsController.getFriends);

module.exports = router;
