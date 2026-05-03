class Match {
  constructor(id, players) {
    this.id = id;
    this.players = players; // Array of player objects
    this.state = 'waiting'; // waiting, playing, finished
    this.startTime = null;
  }

  start() {
    this.state = 'playing';
    this.startTime = Date.now();
  }

  updateProgress(playerId, progress) {
    const player = this.players.find(p => p.id === playerId);
    if (player) {
      player.progress = progress;
    }
  }
}

module.exports = Match;
