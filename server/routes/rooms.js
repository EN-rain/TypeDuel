const express = require('express');
const router = express.Router();
const roomController = require('../controllers/roomController');
const authMiddleware = require('../middleware/auth');

router.post('/create',           authMiddleware, roomController.createRoom);
router.post('/join',             authMiddleware, roomController.joinRoom);
router.post('/matchmake',        authMiddleware, roomController.matchmake);
router.get('/',                  authMiddleware, roomController.listRooms);
router.patch('/:code/select',    authMiddleware, roomController.updateSelections);
router.patch('/:code/phase',     authMiddleware, roomController.updatePhase);
router.patch('/:code/progress',  authMiddleware, roomController.updateProgress);
router.patch('/:code/hp',        authMiddleware, roomController.updateHP);
router.post('/:code/start',      authMiddleware, roomController.startRoomGame);
router.get('/:code',             authMiddleware, roomController.getRoomStatus);
router.delete('/:code',          authMiddleware, roomController.closeRoom);

module.exports = router;
