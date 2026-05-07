/**
 * Socket.io match handler
 *
 * Handles all real-time in-match events. REST endpoints remain the authority
 * for lobby actions (create/join/start/select). Once a game is started, the
 * socket layer takes over for low-latency state sync.
 *
 * Event flow (client → server → broadcast):
 *   skill:pick          → stores skill, if both picked → emits phase:typing to room
 *   typing:progress     → stores progress/typos/mana, emits to opponent
 *   typing:finished     → records first_finish, emits to room
 *   hp:sync             → host pushes HP result, emits to room
 *   forfeit             → marks forfeit, emits to room
 *   match:join          → socket joins the Socket.io room for the match code
 */

const jwt = require('jsonwebtoken');
const { rooms, _enterTypingPhase, roomSnapshot } = require('../controllers/roomController');

const VALID_SKILLS = new Set(['quickslash', 'whiplash', 'soulbreak']);

// Authenticate a socket connection via token in handshake auth or query
function _authSocket(socket) {
    const token = socket.handshake.auth?.token || socket.handshake.query?.token;
    if (!token) return null;
    try {
        return jwt.verify(token, process.env.JWT_SECRET || 'secret');
    } catch {
        return null;
    }
}

function _normalizeCode(code) {
    return String(code || '').toUpperCase();
}

module.exports = (io) => {
    io.on('connection', (socket) => {
        const user = _authSocket(socket);
        if (!user) {
            socket.disconnect(true);
            return;
        }
        const userId = user.id;

        // ── match:join ────────────────────────────────────────────────────────
        // Client calls this once the game scene loads so the socket is in the
        // correct Socket.io room and can receive broadcasts.
        socket.on('match:join', ({ room_code }) => {
            const code = _normalizeCode(room_code);
            const room = rooms[code];
            if (!room) return socket.emit('error', { message: 'Room not found' });
            if (room.host_id != userId && room.guest_id != userId) {
                return socket.emit('error', { message: 'Not in this room' });
            }
            socket.join(code);
            // Send current room state immediately so the client can sync
            socket.emit('room:state', roomSnapshot(room));
        });

        // ── skill:pick ────────────────────────────────────────────────────────
        // Client emits when the player picks (or passes on) a skill.
        // chosen_skill: string skill id, or "" to pass
        socket.on('skill:pick', ({ room_code, chosen_skill }) => {
            const code = _normalizeCode(room_code);
            const room = rooms[code];
            if (!room || room.status !== 'started') return;
            if (room.host_id != userId && room.guest_id != userId) return;
            if (room.phase !== 'skill_select') return;

            const chosen = String(chosen_skill || '');
            if (chosen !== '') {
                if (!VALID_SKILLS.has(chosen)) return socket.emit('error', { message: 'Invalid skill' });
                const mySkills = room.host_id == userId ? room.host_skills : room.guest_skills;
                if (!Array.isArray(mySkills) || !mySkills.includes(chosen)) {
                    return socket.emit('error', { message: 'Skill not in loadout' });
                }
            }

            if (room.host_id == userId) {
                room.host_skill = chosen;
            } else {
                room.guest_skill = chosen;
            }
            room.seq = (room.seq || 0) + 1;

            // Broadcast the pick to the opponent so their UI updates immediately
            io.to(code).emit('skill:picked', {
                role: room.host_id == userId ? 'host' : 'guest',
                chosen_skill: chosen,
            });

            // If both players have committed, advance to typing immediately
            if (room.host_skill !== '' && room.guest_skill !== '') {
                _enterTypingPhase(room, Date.now());
                room.seq = (room.seq || 0) + 1;
                io.to(code).emit('phase:typing', roomSnapshot(room));
            }
        });

        // ── typing:progress ───────────────────────────────────────────────────
        // Throttled on the client side; server just stores and relays.
        socket.on('typing:progress', ({ room_code, progress, typos, mana, chosen_skill }) => {
            const code = _normalizeCode(room_code);
            const room = rooms[code];
            if (!room || room.status !== 'started') return;
            if (room.phase !== 'typing') return;

            const prog = Math.min(1.0, Math.max(0.0, Number(progress) || 0));
            const typosNum = Math.min(500, Math.max(0, Math.floor(Number(typos) || 0)));
            const manaNum = Math.min(10, Math.max(0, Math.floor(Number(mana) || 0)));

            const isHost = room.host_id == userId;
            if (isHost) {
                room.host_progress = prog;
                room.host_typos    = typosNum;
                room.host_mana     = manaNum;
                if (chosen_skill !== undefined) room.host_skill = String(chosen_skill || '');
                if (prog > 0 && room.host_typing_start === 0) room.host_typing_start = Date.now();
            } else {
                room.guest_progress = prog;
                room.guest_typos    = typosNum;
                room.guest_mana     = manaNum;
                if (chosen_skill !== undefined) room.guest_skill = String(chosen_skill || '');
                if (prog > 0 && room.guest_typing_start === 0) room.guest_typing_start = Date.now();
            }
            room.seq = (room.seq || 0) + 1;

            // Relay to opponent only (not back to sender)
            socket.to(code).emit('typing:progress', {
                role:     isHost ? 'host' : 'guest',
                progress: prog,
                typos:    typosNum,
                mana:     manaNum,
            });
        });

        // ── typing:mutation ───────────────────────────────────────────────────
        // Passive mutation to apply to the opponent's sentence.
        socket.on('typing:mutation', ({ room_code, mutation }) => {
            const code = _normalizeCode(room_code);
            const room = rooms[code];
            if (!room || room.status !== 'started' || room.phase !== 'typing') return;

            const isHost = room.host_id == userId;
            if (isHost) {
                room.guest_mutations.push(mutation);
            } else {
                room.host_mutations.push(mutation);
            }
            room.seq = (room.seq || 0) + 1;

            // Send only to opponent
            socket.to(code).emit('typing:mutation', { mutation });
        });

        // ── typing:finished ───────────────────────────────────────────────────
        // Player finished the sentence. Server records first_finish authoritatively.
        socket.on('typing:finished', ({ room_code, progress, typos, mana, chosen_skill }) => {
            const code = _normalizeCode(room_code);
            const room = rooms[code];
            if (!room || room.status !== 'started' || room.phase !== 'typing') return;

            const isHost = room.host_id == userId;
            const prog = Math.min(1.0, Math.max(0.0, Number(progress) || 1.0));
            const typosNum = Math.min(500, Math.max(0, Math.floor(Number(typos) || 0)));
            const manaNum = Math.min(10, Math.max(0, Math.floor(Number(mana) || 0)));

            if (isHost) {
                room.host_progress = prog;
                room.host_typos    = typosNum;
                room.host_mana     = manaNum;
                if (chosen_skill !== undefined) room.host_skill = String(chosen_skill || '');
            } else {
                room.guest_progress = prog;
                room.guest_typos    = typosNum;
                room.guest_mana     = manaNum;
                if (chosen_skill !== undefined) room.guest_skill = String(chosen_skill || '');
            }

            // Record first finish — never overwrite
            if (!room.first_finish_at) {
                room.first_finish_at = Date.now();
                room.first_finish_by = isHost ? 'host' : 'guest';
            }
            room.seq = (room.seq || 0) + 1;

            // Broadcast to the whole room so both clients know immediately
            io.to(code).emit('typing:finished', {
                role:            isHost ? 'host' : 'guest',
                first_finish_at: room.first_finish_at,
                first_finish_by: room.first_finish_by,
                progress:        prog,
                typos:           typosNum,
                mana:            manaNum,
            });
        });

        // ── hp:sync ───────────────────────────────────────────────────────────
        // Host pushes authoritative HP after combat resolution.
        socket.on('hp:sync', ({ room_code, host_hp, guest_hp, host_streak, guest_streak }) => {
            const code = _normalizeCode(room_code);
            const room = rooms[code];
            if (!room || room.status !== 'started') return;
            if (room.host_id != userId) return; // host only

            room.host_hp     = Number(host_hp)     || 0;
            room.guest_hp    = Number(guest_hp)    || 0;
            room.host_streak = Number(host_streak) || 0;
            room.guest_streak = Number(guest_streak) || 0;
            room.seq = (room.seq || 0) + 1;

            // Broadcast to both so guest gets HP update without polling
            io.to(code).emit('hp:sync', {
                host_hp:      room.host_hp,
                guest_hp:     room.guest_hp,
                host_streak:  room.host_streak,
                guest_streak: room.guest_streak,
            });
        });

        // ── phase:skill_select ────────────────────────────────────────────────
        // Host announces start of a new skill-select phase (next round).
        socket.on('phase:skill_select', ({ room_code, round_id }) => {
            const code = _normalizeCode(room_code);
            const room = rooms[code];
            if (!room || room.status !== 'started') return;
            if (room.host_id != userId) return;

            const now = Date.now();
            room.phase            = 'skill_select';
            room.phase_started_at = now;
            room.host_skill       = '';
            room.guest_skill      = '';
            if (typeof round_id === 'number' && round_id > 0) room.round_id = round_id;
            room.seq = (room.seq || 0) + 1;

            io.to(code).emit('phase:skill_select', roomSnapshot(room));
        });

        // ── forfeit ───────────────────────────────────────────────────────────
        socket.on('forfeit', ({ room_code }) => {
            const code = _normalizeCode(room_code);
            const room = rooms[code];
            if (!room || room.status !== 'started') return;
            if (room.host_id != userId && room.guest_id != userId) return;

            const by     = room.host_id == userId ? 'host' : 'guest';
            const winner = by === 'host' ? 'guest' : 'host';
            room.forfeit = { at: Date.now(), by, winner, loser: by, reason: 'leave' };
            room.status  = 'finished';
            room.phase   = 'finished';
            room.seq     = (room.seq || 0) + 1;

            io.to(code).emit('forfeit', { by, winner, loser: by, reason: 'leave' });
        });

        socket.on('disconnect', () => {
            // Presence is still tracked via REST polling heartbeat.
            // The disconnect timeout in roomController handles auto-forfeit.
        });
    });
};
