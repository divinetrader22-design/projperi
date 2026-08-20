// Decorative ambient animation for the dashboard's "Live Feed" panel.
// Two looping scenes (Pac-Man muncher / space shooter) — purely visual, no gameplay.
(function () {
  window.startArcadeCanvas = function (canvasId) {
    const canvas = document.getElementById(canvasId);
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    const W = canvas.width, H = canvas.height;

    let scene = 'pacman';
    let sceneTimer = 0;
    const SCENE_DURATION = 480; // frames per scene (~8s at 60fps)

    // ---------- Pac-Man scene ----------
    const dots = [];
    for (let i = 0; i < 12; i++) dots.push({ x: 20 + i * 22, eaten: false });
    let pac = { x: -20, dir: 1, mouth: 0 };
    const ghostColors = ['#ff6b6b', '#37e8ff', '#ffb84d'];
    const ghosts = ghostColors.map((c, i) => ({ x: -60 - i * 40, color: c }));

    function drawPacman(){
      ctx.clearRect(0, 0, W, H);
      const midY = H / 2;

      // dots
      dots.forEach(d => {
        if (pac.x > d.x - 6 && pac.x < d.x + 6) d.eaten = true;
        if (!d.eaten){
          ctx.beginPath();
          ctx.arc(d.x, midY, 2.5, 0, Math.PI * 2);
          ctx.fillStyle = 'rgba(232,236,247,0.5)';
          ctx.fill();
        }
      });

      // pac-man
      pac.mouth = (Math.sin(sceneTimer * 0.3) + 1) * 0.25;
      ctx.beginPath();
      ctx.fillStyle = '#ffe14d';
      ctx.arc(pac.x, midY, 11, pac.mouth, Math.PI * 2 - pac.mouth);
      ctx.lineTo(pac.x, midY);
      ctx.fill();

      // ghosts trailing behind
      ghosts.forEach(g => {
        ctx.beginPath();
        ctx.arc(g.x, midY, 10, Math.PI, 0);
        ctx.lineTo(g.x + 10, midY + 9);
        ctx.lineTo(g.x + 5, midY + 5);
        ctx.lineTo(g.x, midY + 9);
        ctx.lineTo(g.x - 5, midY + 5);
        ctx.lineTo(g.x - 10, midY + 9);
        ctx.closePath();
        ctx.fillStyle = g.color;
        ctx.globalAlpha = 0.85;
        ctx.fill();
        ctx.globalAlpha = 1;
        g.x += 1.1;
      });

      pac.x += 1.4;
      if (pac.x > W + 20){
        pac.x = -20;
        dots.forEach(d => d.eaten = false);
        ghosts.forEach((g, i) => g.x = -60 - i * 40);
      }
    }

    // ---------- Space shooter scene ----------
    let ship = { x: W / 2, y: H - 22 };
    let lasers = [];
    let asteroids = [];
    let spawnTimer = 0;

    function drawShooter(){
      ctx.clearRect(0, 0, W, H);

      // starfield
      for (let i = 0; i < 30; i++){
        const sx = (i * 53 + sceneTimer * 0.6) % W;
        const sy = (i * 37) % H;
        ctx.fillStyle = 'rgba(232,236,247,0.25)';
        ctx.fillRect(sx, sy, 1.4, 1.4);
      }

      // spawn asteroids
      spawnTimer++;
      if (spawnTimer > 45){
        spawnTimer = 0;
        asteroids.push({ x: Math.random() * (W - 20) + 10, y: -10, r: Math.random() * 6 + 6 });
      }

      // ship drifts side to side
      ship.x = W / 2 + Math.sin(sceneTimer * 0.04) * (W / 2 - 30);

      // fire lasers periodically
      if (sceneTimer % 25 === 0) lasers.push({ x: ship.x, y: ship.y - 10 });

      // update + draw lasers
      lasers.forEach(l => l.y -= 5);
      lasers = lasers.filter(l => l.y > -10);
      ctx.strokeStyle = '#37e8ff';
      ctx.lineWidth = 2;
      lasers.forEach(l => {
        ctx.beginPath();
        ctx.moveTo(l.x, l.y);
        ctx.lineTo(l.x, l.y + 8);
        ctx.stroke();
      });

      // update + draw asteroids, remove on laser hit
      asteroids.forEach(a => a.y += 1.6);
      asteroids = asteroids.filter(a => {
        if (a.y > H + 10) return false;
        const hit = lasers.some(l => Math.abs(l.x - a.x) < a.r && Math.abs(l.y - a.y) < a.r);
        return !hit;
      });
      ctx.fillStyle = '#8291b3';
      asteroids.forEach(a => {
        ctx.beginPath();
        ctx.arc(a.x, a.y, a.r, 0, Math.PI * 2);
        ctx.fill();
      });

      // ship (small triangle)
      ctx.beginPath();
      ctx.moveTo(ship.x, ship.y - 10);
      ctx.lineTo(ship.x - 8, ship.y + 8);
      ctx.lineTo(ship.x + 8, ship.y + 8);
      ctx.closePath();
      ctx.fillStyle = '#7b5cfa';
      ctx.fill();
    }

    function loop(){
      sceneTimer++;
      if (sceneTimer > SCENE_DURATION){
        sceneTimer = 0;
        scene = scene === 'pacman' ? 'shooter' : 'pacman';
        lasers = []; asteroids = [];
      }
      if (scene === 'pacman') drawPacman(); else drawShooter();
      requestAnimationFrame(loop);
    }
    loop();
  };
})();
