const express = require('express');
const router = express.Router();
const gameController = require('../controllers/gameController');

router.get('/leaderboard', gameController.getLeaderboard);
router.get('/online-count', gameController.getOnlineCount);

module.exports = router;
