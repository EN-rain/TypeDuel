const express = require('express');
const router = express.Router();
const gameController = require('../controllers/gameController');

router.get('/leaderboard',   gameController.getLeaderboard);
router.get('/online-count',  gameController.getOnlineCount);
router.post('/heartbeat',    gameController.heartbeat);
router.post('/history',      gameController.saveMatchHistory);
router.get('/history/:user_id', gameController.getMatchHistory);

module.exports = router;
