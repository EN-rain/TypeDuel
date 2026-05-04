const db = require('../config/db');

const dummyData = [
    { username: 'TypeMaster', wins: 50, wpm: 120, accuracy: 98.5 },
    { username: 'KeyboardCat', wins: 42, wpm: 95, accuracy: 92.1 },
    { username: 'SpeedyGonzales', wins: 38, wpm: 110, accuracy: 95.0 },
    { username: 'SlowPoke', wins: 5, wpm: 45, accuracy: 88.2 },
    { username: 'GodotExpert', wins: 25, wpm: 80, accuracy: 99.0 }
];

const run = (sql, params = []) =>
    new Promise((resolve, reject) => {
        db.run(sql, params, function(err) {
            if (err) reject(err);
            else resolve(this);
        });
    });

const get = (sql, params = []) =>
    new Promise((resolve, reject) => {
        db.get(sql, params, (err, row) => {
            if (err) reject(err);
            else resolve(row);
        });
    });

async function ensureUser(username) {
    const existing = await get('SELECT id FROM users WHERE username = ?', [username]);
    if (existing && existing.id) return existing.id;

    await run(
        'INSERT INTO users (username, password, email) VALUES (?, ?, ?)',
        [username, 'password123', `${username.toLowerCase()}@example.com`]
    );

    const created = await get('SELECT id FROM users WHERE username = ?', [username]);
    return created.id;
}

async function upsertLeaderboard(userId, username, wins, wpm, accuracy) {
    const row = await get('SELECT id FROM leaderboard WHERE user_id = ?', [userId]);
    if (row && row.id) {
        await run('UPDATE leaderboard SET wins = ?, wpm = ?, accuracy = ?, username = ? WHERE user_id = ?', [wins, wpm, accuracy, username, userId]);
    } else {
        await run('INSERT INTO leaderboard (user_id, username, wins, wpm, accuracy) VALUES (?, ?, ?, ?, ?)', [userId, username, wins, wpm, accuracy]);
    }
}

async function seed() {
    console.log('Seeding dummy leaderboard data...');

    for (const data of dummyData) {
        try {
            const userId = await ensureUser(data.username);
            await upsertLeaderboard(userId, data.username, data.wins, data.wpm, data.accuracy);
            console.log(`Ensured ${data.username} on leaderboard with ${data.wins} wins.`);
        } catch (err) {
            console.error(`Seed error for ${data.username}:`, err.message);
        }
    }
}

seed();
