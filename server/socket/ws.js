const WebSocket = require('ws');
const jwt = require('jsonwebtoken');
const { rooms, _enterTypingPhase, roomSnapshot } = require('../controllers/roomController');

const VALID_SKILLS = new Set(['quickslash', 'whiplash', 'soulbreak']);

function normalizeCode(code) {
    return String(code || '').toUpperCase();
}

function authenticate(requestUrl) {
    const url = new URL(requestUrl, 'http://localhost');
    const token = url.searchParams.get('token');
    if (!token) return null;
    try {
        return jwt.verify(token, process.env.JWT_SECRET || 'secret');
    } catch {
        return null;
    }
}

function send(ws, event, data = {}) {
    if (ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({ event, ...data }));
}

function broadcast(roomSockets, event, data = {}, except = null) {
    for (const client of roomSockets || []) {
        if (client !== except) send(client, event, data);
    }
}

module.exports = (httpServer) => {
    const wss = new WebSocket.Server({ server: httpServer, path: '/ws' });
    const roomSockets = new Map();

    wss.on('connection', (ws, request) => {
        const user = authenticate(request.url);
        if (!user) {
            ws.close();
            return;
        }

        ws.userId = user.id;
        ws.roomCode = '';

        ws.on('message', (raw) => {
            let message;
            try {
                message = JSON.parse(raw.toString());
            } catch {
                return send(ws, 'error', { message: 'Invalid JSON' });
            }

            const event = String(message.event || '');
            const code = normalizeCode(message.room_code);
            const room = code ? rooms[code] : null;
            const isPlayer = room && (room.host_id == ws.userId || room.guest_id == ws.userId);
            const isHost = room && room.host_id == ws.userId;

            if (event === 'match:join') {
                if (!room) return send(ws, 'error', { message: 'Room not found' });
                if (!isPlayer) return send(ws, 'error', { message: 'Not in this room' });

                ws.roomCode = code;
                if (!roomSockets.has(code)) roomSockets.set(code, new Set());
                roomSockets.get(code).add(ws);
                return send(ws, 'room:state', { room: roomSnapshot(room) });
            }

            if (!room || !isPlayer || room.status !== 'started') return;

            if (event === 'skill:pick') {
                if (room.phase !== 'skill_select') return;
                const chosen = String(message.chosen_skill || '');
                if (chosen !== '') {
                    const loadout = isHost ? room.host_skills : room.guest_skills;
                    if (!VALID_SKILLS.has(chosen)) return send(ws, 'error', { message: 'Invalid skill' });
                    if (!Array.isArray(loadout) || !loadout.includes(chosen)) {
                        return send(ws, 'error', { message: 'Skill not in loadout' });
                    }
                }

                if (isHost) room.host_skill = chosen;
                else room.guest_skill = chosen;
                room.seq = (room.seq || 0) + 1;

                broadcast(roomSockets.get(code), 'skill:picked', {
                    role: isHost ? 'host' : 'guest',
                    chosen_skill: chosen,
                });

                if (room.host_skill && room.guest_skill) {
                    _enterTypingPhase(room, Date.now());
                    room.seq = (room.seq || 0) + 1;
                    broadcast(roomSockets.get(code), 'phase:typing', { room: roomSnapshot(room) });
                }
                return;
            }

            if (event === 'typing:progress' || event === 'typing:finished') {
                if (room.phase !== 'typing') return;
                const progress = Math.min(1, Math.max(0, Number(message.progress) || 0));
                const typos = Math.min(500, Math.max(0, Math.floor(Number(message.typos) || 0)));
                const mana = Math.min(10, Math.max(0, Math.floor(Number(message.mana) || 0)));

                if (isHost) {
                    room.host_progress = progress;
                    room.host_typos = typos;
                    room.host_mana = mana;
                    if (message.chosen_skill !== undefined) room.host_skill = String(message.chosen_skill || '');
                    if (progress > 0 && room.host_typing_start === 0) room.host_typing_start = Date.now();
                } else {
                    room.guest_progress = progress;
                    room.guest_typos = typos;
                    room.guest_mana = mana;
                    if (message.chosen_skill !== undefined) room.guest_skill = String(message.chosen_skill || '');
                    if (progress > 0 && room.guest_typing_start === 0) room.guest_typing_start = Date.now();
                }

                if (event === 'typing:finished' && !room.first_finish_at) {
                    room.first_finish_at = Date.now();
                    room.first_finish_by = isHost ? 'host' : 'guest';
                }

                room.seq = (room.seq || 0) + 1;
                const payload = {
                    role: isHost ? 'host' : 'guest',
                    progress,
                    typos,
                    mana,
                    first_finish_at: room.first_finish_at,
                    first_finish_by: room.first_finish_by,
                };
                broadcast(roomSockets.get(code), event, payload);
                return;
            }

            if (event === 'typing:mutation') {
                if (room.phase !== 'typing') return;
                if (isHost) room.guest_mutations.push(message.mutation);
                else room.host_mutations.push(message.mutation);
                room.seq = (room.seq || 0) + 1;
                broadcast(roomSockets.get(code), 'typing:mutation', { mutation: message.mutation }, ws);
                return;
            }

            if (event === 'hp:sync') {
                if (!isHost) return;
                room.host_hp = Number(message.host_hp) || 0;
                room.guest_hp = Number(message.guest_hp) || 0;
                room.host_streak = Number(message.host_streak) || 0;
                room.guest_streak = Number(message.guest_streak) || 0;
                room.seq = (room.seq || 0) + 1;
                broadcast(roomSockets.get(code), 'hp:sync', {
                    host_hp: room.host_hp,
                    guest_hp: room.guest_hp,
                    host_streak: room.host_streak,
                    guest_streak: room.guest_streak,
                });
                return;
            }

            if (event === 'phase:skill_select') {
                if (!isHost) return;
                room.phase = 'skill_select';
                room.phase_started_at = Date.now();
                room.host_skill = '';
                room.guest_skill = '';
                if (Number(message.round_id) > 0) room.round_id = Number(message.round_id);
                room.seq = (room.seq || 0) + 1;
                broadcast(roomSockets.get(code), 'phase:skill_select', { room: roomSnapshot(room) });
                return;
            }

            if (event === 'forfeit') {
                const by = isHost ? 'host' : 'guest';
                const winner = by === 'host' ? 'guest' : 'host';
                room.forfeit = { at: Date.now(), by, winner, loser: by, reason: 'leave' };
                room.status = 'finished';
                room.phase = 'finished';
                room.seq = (room.seq || 0) + 1;
                broadcast(roomSockets.get(code), 'forfeit', { by, winner, loser: by, reason: 'leave' });
            }
        });

        ws.on('close', () => {
            if (ws.roomCode && roomSockets.has(ws.roomCode)) {
                roomSockets.get(ws.roomCode).delete(ws);
            }
        });
    });
};
