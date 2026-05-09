const express = require('express');
const router = express.Router();
const gameController = require('../controllers/gameController');
const authMiddleware = require('../middleware/auth');

router.get('/leaderboard',   gameController.getLeaderboard);
router.get('/online-count',  gameController.getOnlineCount);
router.post('/heartbeat',    authMiddleware, gameController.heartbeat);
router.post('/history',      authMiddleware, gameController.saveMatchHistory);
router.get('/history/:user_id', authMiddleware, gameController.getMatchHistory);
// apply server-side matchmaking penalty on forfeit
router.post('/matchmaking-penalty', authMiddleware, gameController.applyMatchmakingPenalty);
// DEV ONLY: instantly clear all online sessions (use during debug resets)
router.post('/dev/clear-online', authMiddleware, gameController.clearAllOnline);

module.exports = router;
