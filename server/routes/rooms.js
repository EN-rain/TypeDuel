const express = require('express');
const router = express.Router();
const roomController = require('../controllers/roomController');

router.post('/create',       roomController.createRoom);
router.post('/join',         roomController.joinRoom);
router.post('/matchmake',    roomController.matchmake);
router.get('/:code',         roomController.getRoomStatus);
router.delete('/:code',      roomController.closeRoom);

module.exports = router;
