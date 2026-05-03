module.exports = (io) => {
  io.on('connection', (socket) => {
    console.log('New client connected:', socket.id);

    socket.on('join_match', (data) => {
      // Logic to join a match
    });

    socket.on('type_update', (data) => {
      // Handle typing updates from client
    });

    socket.on('disconnect', () => {
      console.log('Client disconnected');
    });
  });
};
