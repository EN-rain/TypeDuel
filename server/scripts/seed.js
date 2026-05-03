const db = require('../config/db');

const dummyData = [
    { username: 'TypeMaster', wins: 50, wpm: 120, accuracy: 98.5 },
    { username: 'KeyboardCat', wins: 42, wpm: 95, accuracy: 92.1 },
    { username: 'SpeedyGonzales', wins: 38, wpm: 110, accuracy: 95.0 },
    { username: 'SlowPoke', wins: 5, wpm: 45, accuracy: 88.2 },
    { username: 'GodotExpert', wins: 25, wpm: 80, accuracy: 99.0 }
];

async function seed() {
    console.log('Seeding dummy leaderboard data...');

    for (const data of dummyData) {
        // First create a dummy user
        const userSql = 'INSERT INTO users (username, password, email) VALUES (?, ?, ?)';
        db.run(userSql, [data.username, 'password123', `${data.username.toLowerCase()}@example.com`], function(err) {
            if (err) {
                console.log(`User ${data.username} might already exist, skipping user creation.`);
            }
            
            const userId = this ? this.lastID : 1; // Fallback if user exists
            
            // Add to leaderboard
            const leaderboardSql = 'INSERT INTO leaderboard (user_id, username, wins, wpm, accuracy) VALUES (?, ?, ?, ?, ?)';
            db.run(leaderboardSql, [userId, data.username, data.wins, data.wpm, data.accuracy], (err) => {
                if (err) {
                    console.error(`Error adding ${data.username} to leaderboard:`, err.message);
                } else {
                    console.log(`Added ${data.username} to leaderboard with ${data.wins} wins.`);
                }
            });
        });
    }
}

seed();
