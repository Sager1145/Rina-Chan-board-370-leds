console.log('[RinaChanBoard] app.js loaded v2.0.8');
// Local files and localhost are preview-only. Hardware control is enabled only
// when the page itself is served by the ESP32 host.
(function(){
  function isLocalHost(){
    return /^(localhost|127\.0\.0\.1|::1)$/i.test(location.hostname || '');
  }
  function hardwareMode(){
    return (location.protocol === 'http:' || location.protocol === 'https:') && !isLocalHost();
  }
  window.rinaHardwareMode = hardwareMode;
  window.rinaPreviewMode = function(){ return !hardwareMode(); };
  window.rinaApiBase = function(){ return hardwareMode() ? location.origin : 'local-preview'; };
  window.rinaDeviceUrl = function(input){ return input; };
})();
// DATA_BUNDLE_BEGIN
// ─── face_bitmaps.js ───
function horizontalFlip(array) 
{
    return array.map(row => row.slice().reverse());
}

const none = [
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
];

const mouth = [[
    // 1
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,1,1,1,1,1,1,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 2
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [1,0,0,0,0,0,0,1],
    [0,1,1,1,1,1,1,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 3
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [1,0,0,0,0,0,0,1],
    [0,1,0,0,0,0,1,0],
    [0,0,1,1,1,1,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 4
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,1,0,0,0,0,1,0],
    [0,0,1,0,0,1,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 5
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [1,1,1,1,1,1,1,1],
    [1,0,0,0,0,0,0,1],
    [0,1,0,0,0,0,1,0],
    [0,0,1,0,0,1,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 6
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [1,1,1,1,1,1,1,1],
    [1,0,0,0,0,0,0,1],
    [1,0,0,0,0,0,0,1],
    [0,1,0,0,0,0,1,0],
    [0,0,1,1,1,1,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 7
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,1,1,1,1,1,1,0],
    [0,1,0,0,0,0,1,0],
    [0,0,1,0,0,1,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 8
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,1,1,1,1,0,0],
    [0,1,0,0,0,0,1,0],
    [1,0,0,0,0,0,0,1],
    [1,0,0,0,0,0,0,1],
    [1,1,1,1,1,1,1,1],
    [0,0,0,0,0,0,0,0],
],[
    // 9
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [1,1,1,1,1,1,1,1],
    [1,0,0,0,0,0,0,1],
    [0,1,1,1,1,1,1,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 10
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,1,0,0,1,0,0],
    [0,0,1,0,0,1,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 11
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,1,0,0,1,0,0],
    [0,1,0,0,0,0,1,0],
    [0,1,0,0,0,0,1,0],
    [0,0,1,0,0,1,0,0],
    [0,0,0,1,1,0,0,0],
],[
    // 12
    [0,0,0,0,0,0,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,1,0,0,1,0,0],
    [0,0,1,0,0,1,0,0],
    [0,0,1,0,0,1,0,0],
    [0,0,1,0,0,1,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 13
    [0,0,0,1,1,0,0,0],
    [0,0,1,0,0,1,0,0],
    [0,0,1,0,0,1,0,0],
    [0,0,1,0,0,1,0,0],
    [0,0,1,0,0,1,0,0],
    [0,0,1,0,0,1,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 14
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,1,1,1,1,1,1,0],
    [1,0,0,0,0,0,0,1],
    [1,1,1,1,1,1,1,1],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 15
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,1,0,0,1,0,0],
    [0,1,0,1,1,0,1,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 16
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [1,0,0,0,0,0,0,1],
    [0,1,0,0,0,0,1,0],
    [0,1,1,1,1,1,1,0],
    [0,1,0,0,0,0,1,0],
    [1,0,0,0,0,0,0,1],
    [0,0,0,0,0,0,0,0],
],[
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,1,1,1,1,0,0],
    [0,1,0,0,0,0,1,0],
    [0,1,0,0,0,0,1,0],
    [0,0,1,0,0,1,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,1,1,1,1,1,1,0],
    [0,1,0,0,0,0,1,0],
    [0,1,1,1,1,1,1,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,1,1,0,0,1,1,0],
    [1,0,0,1,1,0,0,1],
    [1,0,0,0,0,0,0,1],
    [1,0,0,1,1,0,0,1],
    [0,1,1,0,0,1,1,0],
    [0,0,0,0,0,0,0,0],
]]

const leye = [
[
    // 1
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,1,1,0,0,0,0],
    [0,0,1,1,0,0,0,0],
    [0,0,1,1,0,0,0,0],
    [0,0,1,1,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 2
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,1,0,0,0,0,0,0],
    [0,0,1,1,0,0,0,0],
    [0,0,1,1,0,0,0,0],
    [0,0,1,1,0,0,0,0],
    [0,0,1,1,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 3
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,1,0,0,0],
    [0,0,0,1,0,1,0,0],
    [0,0,1,0,0,0,1,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 4
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,1,1,0,0,0,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,0,0,0,1,0,0],
    [0,0,0,1,1,0,0,0],
    [0,1,1,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 5
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,1,1,0,1,0,0],
    [0,0,1,1,1,1,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 6
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,1,0,0,0,0,0,0],
    [0,0,1,1,1,1,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 7
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,1,1,1,1,1,1,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 8
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,1,1,1,1,1,1,0],
    [1,0,1,0,0,0,0,0],
    [0,1,0,0,0,0,0,0],
],[
    // 9
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,1,1,1,0,0],
    [0,0,1,0,0,0,1,0],
    [0,0,0,0,0,1,0,0],
    [0,0,0,0,1,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,1,0,0,0],
],[
    // 10
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,1,0,0,0],
    [0,0,0,0,1,0,0,0],
    [0,0,0,0,1,0,0,0],
    [0,0,0,0,1,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,1,0,0,0],
],[
    // 11
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,1,1,0,0,0,0],
    [0,0,1,1,1,1,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 12
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,1,0,0,0],
    [0,0,0,1,0,0,0,0],
    [0,1,1,1,0,0,0,0],
    [0,0,1,1,0,0,0,0],
    [0,0,1,1,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 13
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,1,0,0,0,0,0,0],
    [0,0,1,0,0,0,0,0],
    [0,0,1,1,1,0,0,0],
    [0,0,1,1,0,0,0,0],
    [0,0,1,1,0,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 14
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,1,0,0,0,1,0],
    [0,0,0,1,0,1,0,0],
    [0,0,0,0,1,0,0,0],
    [0,0,0,1,0,1,0,0],
    [0,0,1,0,0,0,1,0],
    [0,0,0,0,0,0,0,0],
],[
    // 15
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,1,1,1,0,0],
    [0,0,1,0,0,0,1,0],
    [0,0,1,0,0,0,1,0],
    [0,0,1,0,0,0,1,0],
    [0,0,0,1,1,1,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 16
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,1,1,0,1,1,0],
    [0,1,0,0,1,0,0,1],
    [0,1,0,0,0,0,0,1],
    [0,0,1,0,0,0,1,0],
    [0,0,0,1,0,1,0,0],
    [0,0,0,0,1,0,0,0],
],[
    // 17
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,1,1,0,1,0,0],
    [0,0,1,1,1,1,0,0],
    [0,1,0,1,1,0,0,0],
    [0,0,1,0,0,0,0,0],
],[
    // 18
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,1,1,0,0,0,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,0,0,0,1,0,0],
    [0,1,1,1,1,0,0,0],
    [0,0,0,0,0,0,0,0],
],[
    // 19
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,1,1,0,0,0],
    [0,0,1,0,0,1,0,0],
    [0,1,0,0,0,0,1,0],
    [0,0,0,0,0,0,0,0],
    [0,0,0,0,0,0,0,0],
]];

const reye=[
    horizontalFlip(leye[0]),horizontalFlip(leye[1]),
    horizontalFlip(leye[2]),horizontalFlip(leye[3]),
    horizontalFlip(leye[4]),horizontalFlip(leye[5]),
    horizontalFlip(leye[6]),horizontalFlip(leye[7]),
    horizontalFlip(leye[8]),horizontalFlip(leye[9]),
    horizontalFlip(leye[10]),horizontalFlip(leye[11]),
    horizontalFlip(leye[12]),horizontalFlip(leye[13]),
    horizontalFlip(leye[14]),horizontalFlip(leye[15]),
    horizontalFlip(leye[16]),horizontalFlip(leye[17]),
    horizontalFlip(leye[18]),
];

const cheek00 = [
    [0,0,0,0,0],
    [0,0,0,0,0]
];

const cheek = [[
    // 1
    [0,0,0,0,0],
    [0,0,1,1,0]
],[
    // 2
    [0,0,0,0,0],
    [0,1,0,1,0]
],[
    // 3
    [0,0,1,0,1],
    [0,1,0,1,0]
],[
    // 4
    [0,1,0,1,0],
    [0,0,1,0,1]
]];

window.RINA_FACES = { none, horizontalFlip, mouth, leye, reye, cheek00, cheek };

// ─── device_info.js ───
const device_info=[
    {uid:'null',topic:'null'},
    {uid:'a8a83e1f0a4c4e42b031e1c323dd9159',topic:'RinaChanBoard'},
    {uid:'a8a83e1f0a4c4e42b031e1c323dd9159',topic:'RinaChanBoardExp'},
];

const color_info=[
    {name:'默认璃奈粉色',           color:'f971d4'},
    {name:'高坂穗乃果-橙色',        color:'f38500'},
    {name:'绚濑绘里-水蓝色',        color:'7aeeff'},
    {name:'南小鸟-白色',            color:'cebfbf'},
    {name:'园田海未-蓝色',          color:'1769ff'},
    {name:'星空凛-黄色',            color:'fff832'},
    {name:'西木野真姬-红色',        color:'ff503e'},
    {name:'东条希-紫罗兰色',        color:'c455f6'},
    {name:'小泉花阳-绿色',          color:'6ae673'},
    {name:'矢泽妮可-粉色',          color:'ff4f91'},
    {name:'高海千歌-蜜柑色',        color:'ff9547'},
    {name:'樱内梨子-樱花粉色',      color:'ff9eac'},
    {name:'松浦果南-祖母绿色',      color:'27c1b7'},
    {name:'黑泽黛雅-红色',          color:'db0839'},
    {name:'渡边曜-亮蓝色',          color:'66c0ff'},
    {name:'津岛善子-白色',          color:'c1cad4'},
    {name:'国木田花丸-黄色',        color:'ffd010'},
    {name:'小原鞠莉-紫罗兰色',      color:'c252c6'},
    {name:'黑泽露比-粉色',          color:'ff6fbe'},
    {name:'CYaRon!-橙色',           color:'ffa434'},
    {name:'AZALEA-粉色',            color:'ff5a79'},
    {name:'Guilty Kiss-紫色',       color:'825deb'},
    {name:'鹿角圣良-天蓝色',        color:'00ccff'},
    {name:'鹿角理亚-纯白色',        color:'bbbbbb'},
    {name:'Saint Snow-红色',        color:'cb3935'},
    {name:'高咲侑-黑色',            color:'1d1d1d'},
    {name:'上原步梦-浅粉色',        color:'ed7d95'},
    {name:'中须霞-蜡笔黄色',        color:'e7d600'},
    {name:'樱坂雫-浅蓝色',          color:'01b7ed'},
    {name:'朝香果林-皇室蓝色',      color:'485ec6'},
    {name:'宫下爱-超橙色',          color:'ff5800'},
    {name:'近江彼方-堇色',          color:'a664a0'},
    {name:'优木雪菜-猩红色',        color:'d81c2f'},
    {name:'艾玛·维尔德-浅绿色',     color:'84c36e'},
    {name:'天王寺璃奈-纸白色',      color:'9ca5b9'},
    {name:'三船栞子-翡翠色',        color:'37b484'},
    {name:'米雅·泰勒-白金银色',     color:'a9a898'},
    {name:'钟岚珠-玫瑰金色',        color:'f8c8c4'},
    {name:'DiverDiva-银紫色',       color:'ab76f7'},
    {name:'A·ZU·NA-意大利红色',     color:'ff0042'},
    {name:'QU4RTZ-奶茶色',          color:'d9db83'},
    {name:'R3BIRTH-坦桑蓝色',       color:'424a9d'},
    {name:'涩谷香音-金盏花色',      color:'ff7f27'},
    {name:'唐可可-蜡笔蓝色',        color:'a0fff9'},
    {name:'岚千砂都-桃粉色',        color:'ff6e90'},
    {name:'平安名堇-蜜瓜绿色',      color:'74f466'},
    {name:'叶月恋-宝石蓝色',        color:'0000a0'},
    {name:'樱小路希奈子-玉米黄色',  color:'fff442'},
    {name:'米女芽衣-胭脂红色',      color:'ff3535'},
    {name:'若菜四季-冰绿白色',      color:'b2ffdd'},
    {name:'鬼冢夏美-鬼夏粉色',      color:'ff51c4'},
    {name:'薇恩·玛格丽特-优雅紫色', color:'e49dfd'},
    {name:'鬼冢冬毬-烟熏蓝色',      color:'4cd2e2'},
];

function sleep (time) 
{
    return new Promise((resolve) => setTimeout(resolve, time));
}

window.RINA_COLOR_INFO = color_info; window.RINA_DEVICE_INFO = device_info;

// ─── voice_data.js ───
const FPS=30

const voice_data=[
    {
        id:'vo_na_m0209_0001',
        text:'欢迎回来! 璃奈板,笑一个~',
        faces:[
            {leye: 2,reye: 2,mouth: 6,cheek: 0,during:  6},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,during:  1},
            {leye: 2,reye: 2,mouth: 6,cheek: 0,during:  2},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,during:  9},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  7},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  3},
            {leye: 4,reye: 4,mouth: 6,cheek: 2,during:  1},
            {leye: 4,reye: 4,mouth: 3,cheek: 2,during:  2},
            {leye: 4,reye: 4,mouth: 6,cheek: 2,during:  1},
            {leye: 4,reye: 4,mouth: 3,cheek: 2,during:  2},
            {leye: 4,reye: 4,mouth: 6,cheek: 2,during:  3},
            {leye: 4,reye: 4,mouth: 3,cheek: 2,during:  1},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
        ]
    },
    {
        id:'vo_na_m0209_0002',
        text:'我是......称职的学院偶像吗?',
        faces:[
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  3},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  7},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,during:  2},
            {leye: 6,reye: 6,mouth: 6,cheek: 0,during:  3},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,during:  3},
            {leye: 6,reye: 6,mouth: 6,cheek: 0,during:  2},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,during:  2},
            {leye: 6,reye: 6,mouth: 6,cheek: 0,during:  5},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,during:  3},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  4},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  3},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
        ]
    },
    {
        id:'vo_na_m0209_0003',
        text:'一摸到电脑,就会觉得安心很多~',
        faces:[
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  3},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 4,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 1,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  1},
            {leye: 4,reye: 4,mouth: 3,cheek: 0,during:  1},
            {leye: 4,reye: 4,mouth: 6,cheek: 0,during:  3},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
        ]
    },
    {
        id:'vo_na_m0209_0004',
        text:'感觉最近和你亲近了不少......真开心~',
        faces:[
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  3},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  8},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  4},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  4},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  3},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  3},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  3},
            {leye: 4,reye: 4,mouth: 3,cheek: 2,during:  6},
            {leye: 4,reye: 4,mouth: 6,cheek: 2,during:  2},
            {leye: 4,reye: 4,mouth: 3,cheek: 2,during:  1},
            {leye: 4,reye: 4,mouth: 6,cheek: 2,during:  2},
            {leye: 4,reye: 4,mouth: 3,cheek: 2,during:  6},
            {leye: 4,reye: 4,mouth: 6,cheek: 2,during:  6},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  3},
        ]
    },
    {
        id:'vo_na_m0209_0005',
        text:'我最近跳舞进步了一点,但是还是学不会小跳步.哎你别笑我啊!',
        faces:[
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  7},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  1},
            {leye: 5,reye:17,mouth: 3,cheek: 0,during:  8},
            {leye: 5,reye:17,mouth: 6,cheek: 0,during:  1},
            {leye: 5,reye:17,mouth: 3,cheek: 0,during:  1},
            {leye: 5,reye:17,mouth: 6,cheek: 0,during:  6},
            {leye: 5,reye:17,mouth: 3,cheek: 0,during:  7},
            {leye:11,reye:11,mouth: 3,cheek: 2,during:  3},
            {leye:11,reye:11,mouth: 6,cheek: 2,during:  1},
            {leye:11,reye:11,mouth: 3,cheek: 2,during:  3},
            {leye:11,reye:11,mouth: 6,cheek: 2,during:  8},
            {leye:11,reye:11,mouth: 3,cheek: 2,during:  3},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
        ]
    },
    {
        id:'vo_na_m0209_0006',
        text:'对了,你觉得什么样的璃奈板比较方便呢?',
        faces:[
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  4},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,during:  1},
            {leye: 2,reye: 2,mouth: 6,cheek: 0,during:  4},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,during:  1},
            {leye: 2,reye: 2,mouth: 6,cheek: 0,during:  5},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,during:  3},
            {leye: 2,reye: 2,mouth: 6,cheek: 0,during:  1},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,during:  1},
            {leye: 2,reye: 2,mouth: 6,cheek: 0,during:  1},
            {leye: 9,reye:10,mouth: 6,cheek: 0,during:  1},
            {leye: 9,reye:10,mouth: 3,cheek: 0,during:  1},
            {leye: 9,reye:10,mouth: 6,cheek: 0,during:  2},
            {leye: 9,reye:10,mouth: 3,cheek: 0,during:  1},
            {leye: 9,reye:10,mouth: 6,cheek: 0,during:  1},
            {leye: 9,reye:10,mouth: 3,cheek: 0,during:  2},
            {leye: 9,reye:10,mouth: 6,cheek: 0,during:  5},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  1},
        ]
    },
    {
        id:'vo_na_m0209_0007',
        text:'一起来看学园偶像的影片吧?',
        faces:[
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  2},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,during:  4},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  6},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,during:  2},
            {leye: 2,reye: 2,mouth: 6,cheek: 0,during:  9},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,during:  2},
            {leye: 2,reye: 2,mouth: 6,cheek: 0,during:  1},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,during:  1},
            {leye: 2,reye: 2,mouth: 6,cheek: 0,during:  1},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,during:  4},
            {leye:18,reye:18,mouth: 3,cheek: 0,during:  3},
            {leye:18,reye:18,mouth: 6,cheek: 0,during:  3},
            {leye:18,reye:18,mouth: 3,cheek: 0,during:  1},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,during:  2},
        ]
    },
]

window.RINA_VOICE_DATA = voice_data;

// ─── music_data.js ───
/**
 * 歌曲id的命名规则如下:
 * music_团名_歌手名_歌曲编号_站位_完整版/短版
 * 
 * 团名: 00缪 01水 02虹 03星
 * 
 * 歌手名: 
 * 00 团曲 
 * 01 穗乃果    千歌        步梦        香音
 * 02 绘里      梨子        霞          可可
 * 03 小鸟      果南        雫          千砂都
 * 04 海未      黛雅        果林        堇
 * 05 凛        曜          爱          恋
 * 06 真姬      善子        彼方        希奈子
 * 07 希        花丸        雪菜        芽衣
 * 08 花阳      鞠莉        艾玛        四季
 * 09 妮可      露比        璃奈        夏美
 * 10 /         /           栞子        薇恩
 * 11 /         /           米娅        冬毬
 * 12 /         /           岚珠        /
 * 21 Printemps CYaRon      AZuNa       CatChu
 * 22 BiBi      AZALEA      QU4RTZ      KALEIDOSCORE
 * 23 LilyWhite GuiltyKiss  DiverDiva   5yncri5e
 * 24 /         /           R3Birth     /
 * 31 A-Rise    SaintSnow   /           SunnyPassion
 * 
 * 歌曲编号按照前置条件下的发售顺序
 * 站位按照原歌曲对应歌手编号的站位
 * 完整版为1,短版为0
 */
 
const music_data=[
    {id:'none',name:'未选择',singer:'未选择',text:'选一首你想要播放的歌曲吧!',faces:[{leye:1,reye:1,mouth:3,cheek:0,frame:0},{leye:1,reye:1,mouth:3,cheek:0,frame:1},]},
    {
        id:'music_02_09_02_00_1',
        name:'Teletelepathy',
        cover_src:'https://www.738ngx.site/api/rinachanboard/images/cover/music_02_09_02.png',
        music_src:'https://www.738ngx.site/api/rinachanboard/musics/music_02_09_02_1.mp3',
        singer:'天王寺璃奈(田中ちえ美)',
        text:  'テレテレパシー是虹咲学园学园偶像同好会第二张专辑《Love U my friends》收录曲之一，由天王寺璃奈演唱，发售于2019年10月2日。本曲在虹咲TV动画二期第13话用作插曲。',
        faces:[
            {"leye":6,"reye":6,"mouth":3,"cheek":0,"frame":0},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":55},
            {"leye":1,"reye":4,"mouth":7,"cheek":2,"frame":115},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":120},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":131},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":134},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":136},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":137},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":140},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":144},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":149},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":150},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":151},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":153},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":154},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":157},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":159},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":160},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":161},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":162},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":168},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":169},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":170},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":172},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":173},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":174},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":176},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":177},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":178},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":179},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":182},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":183},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":185},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":186},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":187},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":188},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":189},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":190},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":192},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":193},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":194},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":198},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":199},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":200},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":202},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":203},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":204},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":205},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":207},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":209},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":214},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":217},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":219},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":220},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":221},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":222},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":225},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":229},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":236},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":237},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":238},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":239},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":241},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":242},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":243},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":244},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":247},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":248},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":249},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":253},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":254},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":255},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":256},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":259},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":261},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":262},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":263},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":264},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":266},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":267},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":273},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":276},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":278},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":280},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":281},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":282},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":284},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":287},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":289},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":292},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":295},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":310},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":311},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":320},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":396},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":397},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":399},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":401},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":403},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":405},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":406},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":407},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":408},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":409},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":412},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":413},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":414},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":416},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":417},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":418},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":419},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":422},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":424},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":426},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":427},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":428},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":429},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":431},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":432},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":436},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":438},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":440},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":443},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":444},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":445},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":446},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":447},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":448},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":449},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":450},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":451},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":452},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":454},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":455},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":457},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":458},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":459},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":463},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":464},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":465},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":466},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":467},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":469},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":470},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":475},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":476},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":477},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":478},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":479},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":481},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":482},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":483},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":485},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":486},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":489},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":490},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":494},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":495},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":496},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":498},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":501},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":502},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":503},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":504},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":505},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":506},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":507},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":509},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":511},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":513},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":516},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":517},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":518},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":520},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":526},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":529},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":532},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":533},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":534},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":536},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":537},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":538},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":539},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":540},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":542},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":543},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":544},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":545},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":546},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":551},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":555},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":556},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":557},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":559},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":560},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":562},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":565},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":566},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":567},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":568},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":569},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":571},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":572},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":573},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":574},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":575},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":578},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":579},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":580},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":582},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":583},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":584},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":585},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":586},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":587},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":589},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":595},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":596},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":597},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":598},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":601},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":602},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":603},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":609},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":610},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":611},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":612},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":613},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":614},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":615},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":618},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":619},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":621},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":622},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":627},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":629},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":631},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":632},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":638},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":639},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":641},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":642},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":643},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":647},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":648},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":649},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":650},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":651},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":664},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":677},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":678},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":682},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":683},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":684},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":685},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":689},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":690},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":691},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":692},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":693},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":694},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":695},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":697},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":698},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":700},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":701},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":703},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":706},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":707},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":709},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":714},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":715},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":717},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":718},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":719},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":720},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":722},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":723},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":724},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":726},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":727},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":728},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":730},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":731},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":733},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":734},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":735},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":736},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":738},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":739},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":740},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":744},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":746},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":749},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":752},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":753},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":754},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":755},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":759},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":762},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":763},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":764},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":765},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":766},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":772},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":773},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":775},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":777},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":778},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":781},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":782},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":783},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":784},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":785},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":786},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":789},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":790},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":793},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":794},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":797},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":798},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":799},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":800},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":801},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":802},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":803},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":807},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":809},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":813},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":815},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":816},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":817},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":818},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":819},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":820},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":822},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":823},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":827},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":829},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":832},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":834},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":835},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":838},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":839},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":840},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":841},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":842},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":843},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":844},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":847},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":848},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":849},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":850},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":851},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":852},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":853},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":854},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":855},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":856},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":859},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":860},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":861},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":862},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":863},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":864},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":867},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":868},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":869},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":870},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":871},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":873},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":875},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":877},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":878},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":879},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":880},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":881},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":882},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":885},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":886},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":887},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":891},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":896},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":898},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":899},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":901},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":903},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":908},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":909},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":910},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":913},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":915},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":916},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":917},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":918},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":921},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":923},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":925},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":926},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":927},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":928},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":932},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":933},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":934},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":935},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":936},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":938},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":942},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":943},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":951},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":952},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":953},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":956},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":958},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":960},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":961},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":962},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":964},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":965},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":966},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":967},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":968},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":970},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":990},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":993},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":999},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1077},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1078},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1079},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1081},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1082},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1083},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1084},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1085},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1086},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1088},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1089},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1090},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1092},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1094},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1095},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1099},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1100},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1101},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1103},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1106},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1107},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1108},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1110},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1111},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1113},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1114},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1115},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1116},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1118},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1119},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1120},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1121},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1122},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1124},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1125},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1127},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1128},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1129},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1130},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1132},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1133},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1134},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1136},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1137},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1138},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1139},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1140},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1141},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1143},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1144},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1146},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1147},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1148},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1150},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1154},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1156},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1157},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1158},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1159},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1160},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1161},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1164},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1165},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1166},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1167},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1168},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1172},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1174},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1175},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1177},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1180},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1181},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1183},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1184},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1185},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1187},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1189},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1192},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1204},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1207},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1209},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1210},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1212},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1214},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1218},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1220},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1221},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1222},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1224},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1227},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1228},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1231},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1232},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1233},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1236},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1237},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1238},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1239},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1241},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1242},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1243},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1245},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1246},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1247},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1249},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1250},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1251},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1252},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1255},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1256},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1257},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1258},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1260},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1261},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1262},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1266},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1267},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1268},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1271},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1272},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1274},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1275},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1277},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1281},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1288},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1289},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1290},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1292},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1293},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1294},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1296},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1297},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1299},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1300},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1303},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1304},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1305},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1306},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1307},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1310},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1311},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1316},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1317},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1318},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1322},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1326},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1327},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1328},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1329},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1330},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1332},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1342},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1344},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1356},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1357},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1358},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1361},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1363},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1364},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1368},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1369},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1370},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1373},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1374},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1375},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1376},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1379},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1380},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1382},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1384},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1385},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1386},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1387},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1388},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1389},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1390},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1393},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1394},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1395},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1396},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1397},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1398},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1399},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1400},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1401},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1402},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1404},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1406},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1408},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1409},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1410},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1411},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1412},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1413},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1414},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1415},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1417},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1418},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1419},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1422},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1423},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1425},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1426},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1431},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1432},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1433},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1434},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1436},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1439},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1440},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1444},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1445},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1446},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1447},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1448},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1452},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1453},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1454},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1455},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1456},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1460},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1461},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1464},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1465},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1468},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1469},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1471},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1472},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1473},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1478},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1479},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1480},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1485},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1489},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1492},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1493},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1494},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1495},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1496},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1497},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1500},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1502},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1505},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1506},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1508},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1509},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1512},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1513},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1514},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1517},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1520},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1522},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1524},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1526},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1527},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1528},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1530},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1533},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1534},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1537},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1538},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1539},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1541},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1542},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1543},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1544},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1545},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1546},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1547},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1550},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1551},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1552},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1554},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1555},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1557},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1558},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1561},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1562},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1563},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1564},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1565},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1570},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1575},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1576},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1577},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1580},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1583},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1586},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1587},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1588},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1589},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1592},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1593},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1597},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1600},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1601},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1604},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1605},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1606},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1607},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1608},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1610},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1611},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1612},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1613},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1614},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1618},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1621},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1622},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1627},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1628},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1629},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1630},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1631},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1633},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1635},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1638},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1639},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1640},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1641},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1644},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1645},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1647},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1649},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1654},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1657},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1660},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1661},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1664},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1665},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1666},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1669},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1670},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1671},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1674},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1675},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1676},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1677},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1681},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1682},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1685},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1686},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1688},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1690},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1693},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1694},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1695},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1696},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1698},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1702},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1703},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1704},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1707},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1709},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1710},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1711},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1712},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1713},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1714},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1715},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1717},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1718},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1719},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1721},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1722},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1725},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1726},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1728},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1730},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1732},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1733},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1734},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1737},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1738},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1740},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1741},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1743},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1745},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1746},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1749},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1750},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1753},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1757},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1758},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1760},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1761},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1766},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1767},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1769},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1771},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1777},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1779},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1780},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1781},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1790},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1791},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1801},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1802},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1804},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1805},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1806},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1807},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1808},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1809},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1810},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1811},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1812},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1815},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1816},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1822},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1825},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1827},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1828},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1829},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1830},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1834},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1835},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1837},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1838},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1839},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1841},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1843},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1845},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1847},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1848},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1850},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1851},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1853},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1856},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1857},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1862},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1864},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1865},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1866},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1867},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1869},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1870},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1871},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1872},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1873},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1874},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1875},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1876},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1879},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1880},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1882},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1885},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1886},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1887},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1888},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1889},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1891},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1893},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1895},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1898},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1899},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1905},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1907},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1908},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1910},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1911},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1913},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1914},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1915},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1916},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1918},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1920},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1921},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1922},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1924},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1926},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1927},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1928},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1930},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1932},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1934},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1935},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1936},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1938},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1939},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1940},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1944},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1945},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1947},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1948},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1949},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1952},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1953},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1960},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1961},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1962},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1963},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1964},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1966},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1968},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1969},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1972},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1973},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1976},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1977},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1978},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1980},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1981},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1983},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1986},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1988},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2018},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2021},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2023},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":2024},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2025},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2026},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2030},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2031},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2032},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2034},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2035},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2036},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2037},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2039},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2040},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2042},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":2043},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2044},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2045},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2047},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2048},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2050},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2051},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2052},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2054},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2055},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2056},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2057},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2060},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2063},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2064},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2065},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2067},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2068},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2069},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2071},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2072},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2073},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2074},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2075},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":2076},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2077},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2079},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2080},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2081},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2085},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2087},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2092},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2095},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2096},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2097},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2099},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2100},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2101},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2102},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2104},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2105},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2106},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2107},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":2109},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2110},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2111},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2112},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2114},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2115},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2116},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":2120},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2123},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":2125},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2126},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2128},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2130},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2131},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2134},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2135},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2143},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2144},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2148},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2150},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2151},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2152},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2154},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2157},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2158},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2159},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2161},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2162},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2164},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2165},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2166},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2168},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2169},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2170},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2175},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2176},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2179},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2180},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2181},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2182},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2184},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2185},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":2186},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2188},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2189},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2190},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2191},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2192},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2193},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2195},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2196},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2197},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2198},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2202},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2204},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2205},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2207},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2208},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2209},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2210},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2212},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2213},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2214},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":2216},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2217},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2218},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2219},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":2220},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2221},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2222},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":2223},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2226},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2227},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2228},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2229},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2233},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2234},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2235},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2237},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":2238},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2239},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2240},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2241},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2245},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2248},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2250},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2251},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2254},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":2255},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2256},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2258},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2259},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2262},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2263},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2264},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2265},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2266},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2268},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2271},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2272},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2275},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2279},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2283},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2284},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2285},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2289},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2290},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2294},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2295},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2296},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2300},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":2301},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2302},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2305},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2306},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2308},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2310},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2311},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2315},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2317},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2330},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2334},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2335},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2336},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2337},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2338},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2339},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2348},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":2349},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":2460},
        ]
    },
    {
        id:'music_02_09_04_00_1',
        name:'相连的Connect',
        cover_src:'https://www.738ngx.site/api/rinachanboard/images/cover/music_02_09_04.png',
        music_src:'https://www.738ngx.site/api/rinachanboard/musics/music_02_09_04_1.mp3',
        singer:'天王寺璃奈(田中ちえ美)',
        text:  'ツナガルコネクト是《LoveLive!虹咲学园学园偶像同好会》动画第一季第六集的插入曲，由天王寺璃奈演唱。歌曲收录于动画第一季第二张插入曲单曲《サイコーハート / La Bella Patria / ツナガルコネクト》中，发售于2020年12月2日。',
        faces:[
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":0},
            {"leye":6,"reye":6,"mouth":3,"cheek":0,"frame":30},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":32},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":35},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":36},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":37},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":39},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":41},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":44},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":45},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":46},
            {"leye":4,"reye":4,"mouth":3,"cheek":3,"frame":47},
            {"leye":4,"reye":4,"mouth":9,"cheek":3,"frame":48},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":49},
            {"leye":4,"reye":4,"mouth":12,"cheek":3,"frame":50},
            {"leye":4,"reye":4,"mouth":17,"cheek":3,"frame":51},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":52},
            {"leye":4,"reye":4,"mouth":3,"cheek":3,"frame":54},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":55},
            {"leye":2,"reye":2,"mouth":6,"cheek":2,"frame":62},
            {"leye":2,"reye":2,"mouth":12,"cheek":2,"frame":66},
            {"leye":2,"reye":2,"mouth":6,"cheek":2,"frame":67},
            {"leye":1,"reye":1,"mouth":9,"cheek":2,"frame":71},
            {"leye":1,"reye":1,"mouth":17,"cheek":2,"frame":72},
            {"leye":1,"reye":1,"mouth":6,"cheek":2,"frame":73},
            {"leye":1,"reye":1,"mouth":9,"cheek":2,"frame":76},
            {"leye":1,"reye":1,"mouth":6,"cheek":2,"frame":77},
            {"leye":1,"reye":1,"mouth":9,"cheek":2,"frame":83},
            {"leye":19,"reye":19,"mouth":10,"cheek":3,"frame":85},
            {"leye":19,"reye":19,"mouth":6,"cheek":3,"frame":86},
            {"leye":19,"reye":19,"mouth":12,"cheek":3,"frame":88},
            {"leye":2,"reye":2,"mouth":6,"cheek":2,"frame":90},
            {"leye":2,"reye":2,"mouth":12,"cheek":2,"frame":92},
            {"leye":4,"reye":4,"mouth":6,"cheek":2,"frame":94},
            {"leye":4,"reye":4,"mouth":12,"cheek":2,"frame":95},
            {"leye":4,"reye":4,"mouth":6,"cheek":2,"frame":96},
            {"leye":4,"reye":4,"mouth":12,"cheek":2,"frame":97},
            {"leye":4,"reye":4,"mouth":6,"cheek":2,"frame":98},
            {"leye":4,"reye":4,"mouth":17,"cheek":2,"frame":103},
            {"leye":4,"reye":4,"mouth":6,"cheek":2,"frame":104},
            {"leye":4,"reye":4,"mouth":10,"cheek":2,"frame":107},
            {"leye":4,"reye":4,"mouth":17,"cheek":2,"frame":109},
            {"leye":1,"reye":1,"mouth":6,"cheek":2,"frame":111},
            {"leye":1,"reye":1,"mouth":10,"cheek":2,"frame":112},
            {"leye":1,"reye":1,"mouth":17,"cheek":2,"frame":114},
            {"leye":1,"reye":1,"mouth":6,"cheek":2,"frame":115},
            {"leye":1,"reye":1,"mouth":12,"cheek":2,"frame":121},
            {"leye":1,"reye":1,"mouth":6,"cheek":2,"frame":123},
            {"leye":1,"reye":1,"mouth":9,"cheek":2,"frame":131},
            {"leye":19,"reye":19,"mouth":6,"cheek":2,"frame":132},
            {"leye":19,"reye":19,"mouth":17,"cheek":2,"frame":140},
            {"leye":19,"reye":19,"mouth":6,"cheek":2,"frame":141},
            {"leye":2,"reye":2,"mouth":17,"cheek":2,"frame":144},
            {"leye":2,"reye":2,"mouth":6,"cheek":2,"frame":145},
            {"leye":2,"reye":2,"mouth":17,"cheek":2,"frame":147},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":149},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":153},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":154},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":155},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":157},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":159},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":161},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":162},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":163},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":165},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":166},
            {"leye":4,"reye":4,"mouth":17,"cheek":0,"frame":167},
            {"leye":4,"reye":4,"mouth":9,"cheek":0,"frame":168},
            {"leye":4,"reye":4,"mouth":6,"cheek":0,"frame":170},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":198},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":202},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":204},
            {"leye":6,"reye":6,"mouth":3,"cheek":0,"frame":206},
            {"leye":5,"reye":5,"mouth":6,"cheek":0,"frame":207},
            {"leye":5,"reye":5,"mouth":12,"cheek":0,"frame":209},
            {"leye":5,"reye":5,"mouth":6,"cheek":0,"frame":210},
            {"leye":5,"reye":5,"mouth":12,"cheek":0,"frame":211},
            {"leye":5,"reye":5,"mouth":6,"cheek":0,"frame":213},
            {"leye":5,"reye":5,"mouth":12,"cheek":0,"frame":214},
            {"leye":5,"reye":5,"mouth":17,"cheek":0,"frame":217},
            {"leye":5,"reye":5,"mouth":6,"cheek":0,"frame":218},
            {"leye":4,"reye":4,"mouth":17,"cheek":0,"frame":219},
            {"leye":4,"reye":4,"mouth":9,"cheek":0,"frame":220},
            {"leye":4,"reye":4,"mouth":10,"cheek":0,"frame":221},
            {"leye":4,"reye":4,"mouth":17,"cheek":0,"frame":224},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":225},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":229},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":230},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":233},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":238},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":240},
            {"leye":6,"reye":6,"mouth":17,"cheek":0,"frame":242},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":243},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":244},
            {"leye":6,"reye":6,"mouth":15,"cheek":0,"frame":247},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":252},
            {"leye":5,"reye":5,"mouth":12,"cheek":0,"frame":255},
            {"leye":4,"reye":4,"mouth":6,"cheek":0,"frame":257},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":259},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":260},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":264},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":265},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":266},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":268},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":269},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":272},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":273},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":275},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":276},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":278},
            {"leye":6,"reye":6,"mouth":10,"cheek":0,"frame":279},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":280},
            {"leye":5,"reye":17,"mouth":12,"cheek":0,"frame":281},
            {"leye":5,"reye":17,"mouth":9,"cheek":0,"frame":287},
            {"leye":5,"reye":17,"mouth":6,"cheek":0,"frame":288},
            {"leye":5,"reye":17,"mouth":12,"cheek":0,"frame":289},
            {"leye":5,"reye":17,"mouth":6,"cheek":0,"frame":293},
            {"leye":5,"reye":17,"mouth":12,"cheek":0,"frame":295},
            {"leye":5,"reye":17,"mouth":17,"cheek":0,"frame":296},
            {"leye":5,"reye":17,"mouth":6,"cheek":0,"frame":297},
            {"leye":5,"reye":17,"mouth":12,"cheek":0,"frame":301},
            {"leye":5,"reye":17,"mouth":6,"cheek":0,"frame":302},
            {"leye":5,"reye":17,"mouth":12,"cheek":0,"frame":306},
            {"leye":4,"reye":4,"mouth":6,"cheek":0,"frame":307},
            {"leye":4,"reye":4,"mouth":12,"cheek":0,"frame":309},
            {"leye":4,"reye":4,"mouth":10,"cheek":0,"frame":310},
            {"leye":4,"reye":4,"mouth":6,"cheek":0,"frame":311},
            {"leye":4,"reye":4,"mouth":9,"cheek":0,"frame":312},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":314},
            {"leye":6,"reye":6,"mouth":17,"cheek":0,"frame":315},
            {"leye":5,"reye":17,"mouth":9,"cheek":0,"frame":316},
            {"leye":5,"reye":17,"mouth":6,"cheek":0,"frame":317},
            {"leye":5,"reye":17,"mouth":9,"cheek":0,"frame":318},
            {"leye":5,"reye":17,"mouth":10,"cheek":0,"frame":319},
            {"leye":5,"reye":17,"mouth":9,"cheek":0,"frame":320},
            {"leye":5,"reye":17,"mouth":6,"cheek":0,"frame":321},
            {"leye":5,"reye":17,"mouth":9,"cheek":0,"frame":322},
            {"leye":5,"reye":17,"mouth":12,"cheek":0,"frame":323},
            {"leye":5,"reye":17,"mouth":6,"cheek":0,"frame":327},
            {"leye":5,"reye":17,"mouth":9,"cheek":0,"frame":328},
            {"leye":9,"reye":10,"mouth":6,"cheek":0,"frame":329},
            {"leye":9,"reye":10,"mouth":17,"cheek":0,"frame":334},
            {"leye":9,"reye":10,"mouth":12,"cheek":0,"frame":336},
            {"leye":9,"reye":10,"mouth":9,"cheek":0,"frame":340},
            {"leye":9,"reye":10,"mouth":6,"cheek":0,"frame":341},
            {"leye":9,"reye":10,"mouth":12,"cheek":0,"frame":342},
            {"leye":9,"reye":10,"mouth":17,"cheek":0,"frame":344},
            {"leye":9,"reye":10,"mouth":6,"cheek":0,"frame":348},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":349},
            {"leye":6,"reye":6,"mouth":9,"cheek":0,"frame":350},
            {"leye":4,"reye":4,"mouth":17,"cheek":3,"frame":351},
            {"leye":4,"reye":4,"mouth":9,"cheek":3,"frame":353},
            {"leye":4,"reye":4,"mouth":17,"cheek":3,"frame":354},
            {"leye":4,"reye":4,"mouth":12,"cheek":3,"frame":355},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":356},
            {"leye":4,"reye":4,"mouth":9,"cheek":3,"frame":360},
            {"leye":4,"reye":4,"mouth":17,"cheek":3,"frame":361},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":362},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":363},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":364},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":365},
            {"leye":6,"reye":6,"mouth":3,"cheek":0,"frame":368},
            {"leye":11,"reye":11,"mouth":6,"cheek":0,"frame":369},
            {"leye":11,"reye":11,"mouth":12,"cheek":0,"frame":371},
            {"leye":11,"reye":11,"mouth":6,"cheek":0,"frame":372},
            {"leye":11,"reye":11,"mouth":12,"cheek":0,"frame":377},
            {"leye":11,"reye":11,"mouth":6,"cheek":0,"frame":379},
            {"leye":11,"reye":11,"mouth":9,"cheek":2,"frame":381},
            {"leye":11,"reye":11,"mouth":6,"cheek":2,"frame":382},
            {"leye":11,"reye":11,"mouth":12,"cheek":2,"frame":385},
            {"leye":11,"reye":11,"mouth":6,"cheek":2,"frame":386},
            {"leye":11,"reye":11,"mouth":10,"cheek":2,"frame":387},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":389},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":390},
            {"leye":19,"reye":19,"mouth":17,"cheek":0,"frame":392},
            {"leye":19,"reye":19,"mouth":6,"cheek":0,"frame":395},
            {"leye":19,"reye":19,"mouth":12,"cheek":0,"frame":396},
            {"leye":19,"reye":19,"mouth":6,"cheek":0,"frame":401},
            {"leye":5,"reye":5,"mouth":12,"cheek":0,"frame":404},
            {"leye":5,"reye":5,"mouth":9,"cheek":0,"frame":405},
            {"leye":5,"reye":5,"mouth":6,"cheek":0,"frame":406},
            {"leye":5,"reye":5,"mouth":17,"cheek":0,"frame":407},
            {"leye":5,"reye":5,"mouth":6,"cheek":0,"frame":408},
            {"leye":5,"reye":5,"mouth":17,"cheek":0,"frame":409},
            {"leye":5,"reye":5,"mouth":10,"cheek":0,"frame":410},
            {"leye":5,"reye":5,"mouth":12,"cheek":0,"frame":411},
            {"leye":7,"reye":8,"mouth":6,"cheek":0,"frame":412},
            {"leye":7,"reye":8,"mouth":3,"cheek":0,"frame":414},
            {"leye":7,"reye":8,"mouth":6,"cheek":0,"frame":415},
            {"leye":4,"reye":2,"mouth":17,"cheek":0,"frame":424},
            {"leye":4,"reye":2,"mouth":6,"cheek":0,"frame":425},
            {"leye":4,"reye":2,"mouth":12,"cheek":0,"frame":427},
            {"leye":4,"reye":2,"mouth":6,"cheek":0,"frame":428},
            {"leye":2,"reye":4,"mouth":12,"cheek":0,"frame":430},
            {"leye":2,"reye":4,"mouth":17,"cheek":0,"frame":431},
            {"leye":2,"reye":4,"mouth":6,"cheek":0,"frame":433},
            {"leye":2,"reye":4,"mouth":17,"cheek":0,"frame":435},
            {"leye":2,"reye":4,"mouth":6,"cheek":0,"frame":436},
            {"leye":2,"reye":4,"mouth":12,"cheek":0,"frame":439},
            {"leye":2,"reye":4,"mouth":9,"cheek":0,"frame":441},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":442},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":444},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":445},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":447},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":449},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":451},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":452},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":454},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":456},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":457},
            {"leye":6,"reye":6,"mouth":17,"cheek":0,"frame":458},
            {"leye":6,"reye":6,"mouth":9,"cheek":0,"frame":460},
            {"leye":6,"reye":6,"mouth":17,"cheek":0,"frame":461},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":462},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":463},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":464},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":466},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":467},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":470},
            {"leye":2,"reye":2,"mouth":6,"cheek":3,"frame":471},
            {"leye":2,"reye":2,"mouth":12,"cheek":3,"frame":472},
            {"leye":2,"reye":2,"mouth":6,"cheek":3,"frame":473},
            {"leye":2,"reye":2,"mouth":9,"cheek":3,"frame":474},
            {"leye":2,"reye":2,"mouth":6,"cheek":3,"frame":475},
            {"leye":2,"reye":2,"mouth":17,"cheek":3,"frame":476},
            {"leye":2,"reye":2,"mouth":12,"cheek":3,"frame":480},
            {"leye":2,"reye":2,"mouth":9,"cheek":3,"frame":481},
            {"leye":2,"reye":2,"mouth":6,"cheek":3,"frame":482},
            {"leye":2,"reye":2,"mouth":9,"cheek":3,"frame":484},
            {"leye":2,"reye":2,"mouth":6,"cheek":3,"frame":488},
            {"leye":2,"reye":2,"mouth":9,"cheek":3,"frame":492},
            {"leye":2,"reye":2,"mouth":6,"cheek":3,"frame":494},
            {"leye":2,"reye":2,"mouth":9,"cheek":3,"frame":516},
            {"leye":2,"reye":2,"mouth":17,"cheek":3,"frame":517},
            {"leye":2,"reye":2,"mouth":6,"cheek":3,"frame":518},
            {"leye":2,"reye":2,"mouth":17,"cheek":3,"frame":520},
            {"leye":4,"reye":4,"mouth":12,"cheek":0,"frame":522},
            {"leye":4,"reye":4,"mouth":6,"cheek":0,"frame":525},
            {"leye":4,"reye":4,"mouth":3,"cheek":0,"frame":528},
            {"leye":4,"reye":4,"mouth":9,"cheek":0,"frame":529},
            {"leye":4,"reye":4,"mouth":6,"cheek":0,"frame":530},
            {"leye":4,"reye":4,"mouth":12,"cheek":0,"frame":544},
            {"leye":4,"reye":4,"mouth":6,"cheek":0,"frame":545},
            {"leye":4,"reye":4,"mouth":12,"cheek":0,"frame":546},
            {"leye":4,"reye":4,"mouth":9,"cheek":0,"frame":550},
            {"leye":4,"reye":4,"mouth":3,"cheek":0,"frame":552},
            {"leye":4,"reye":4,"mouth":17,"cheek":0,"frame":554},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":555},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":556},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":558},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":559},
            {"leye":4,"reye":4,"mouth":9,"cheek":2,"frame":563},
            {"leye":4,"reye":4,"mouth":6,"cheek":2,"frame":564},
            {"leye":4,"reye":4,"mouth":12,"cheek":2,"frame":565},
            {"leye":4,"reye":4,"mouth":6,"cheek":2,"frame":566},
            {"leye":4,"reye":4,"mouth":9,"cheek":2,"frame":568},
            {"leye":4,"reye":4,"mouth":6,"cheek":2,"frame":569},
            {"leye":1,"reye":1,"mouth":12,"cheek":3,"frame":570},
            {"leye":1,"reye":1,"mouth":6,"cheek":3,"frame":572},
            {"leye":1,"reye":1,"mouth":12,"cheek":3,"frame":573},
            {"leye":1,"reye":1,"mouth":6,"cheek":3,"frame":575},
            {"leye":4,"reye":4,"mouth":17,"cheek":3,"frame":578},
            {"leye":4,"reye":4,"mouth":3,"cheek":3,"frame":580},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":581},
            {"leye":4,"reye":4,"mouth":12,"cheek":3,"frame":582},
            {"leye":4,"reye":4,"mouth":17,"cheek":0,"frame":584},
            {"leye":2,"reye":2,"mouth":12,"cheek":0,"frame":586},
            {"leye":2,"reye":2,"mouth":6,"cheek":0,"frame":588},
            {"leye":2,"reye":2,"mouth":17,"cheek":0,"frame":589},
            {"leye":2,"reye":2,"mouth":6,"cheek":0,"frame":594},
            {"leye":2,"reye":2,"mouth":9,"cheek":0,"frame":596},
            {"leye":6,"reye":6,"mouth":10,"cheek":0,"frame":599},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":602},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":603},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":605},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":606},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":608},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":609},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":611},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":613},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":615},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":616},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":617},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":618},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":624},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":626},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":628},
            {"leye":6,"reye":6,"mouth":17,"cheek":0,"frame":629},
            {"leye":6,"reye":6,"mouth":9,"cheek":0,"frame":630},
            {"leye":6,"reye":6,"mouth":17,"cheek":0,"frame":632},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":633},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":636},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":637},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":638},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":639},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":641},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":642},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":644},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":646},
            {"leye":4,"reye":2,"mouth":6,"cheek":3,"frame":648},
            {"leye":4,"reye":2,"mouth":9,"cheek":3,"frame":649},
            {"leye":4,"reye":2,"mouth":17,"cheek":3,"frame":650},
            {"leye":4,"reye":2,"mouth":6,"cheek":3,"frame":651},
            {"leye":4,"reye":2,"mouth":17,"cheek":3,"frame":653},
            {"leye":4,"reye":2,"mouth":10,"cheek":3,"frame":654},
            {"leye":4,"reye":2,"mouth":6,"cheek":3,"frame":656},
            {"leye":5,"reye":5,"mouth":12,"cheek":3,"frame":662},
            {"leye":5,"reye":5,"mouth":6,"cheek":3,"frame":663},
            {"leye":5,"reye":5,"0mouth":3,"cheek":3,"frame":664},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":665},
            {"leye":4,"reye":4,"mouth":17,"cheek":3,"frame":666},
            {"leye":4,"reye":4,"mouth":10,"cheek":3,"frame":670},
            {"leye":4,"reye":4,"mouth":9,"cheek":3,"frame":671},
            {"leye":4,"reye":4,"mouth":17,"cheek":3,"frame":672},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":676},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":678},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":679},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":680},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":684},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":685},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":686},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":687},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":688},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":689},
            {"leye":2,"reye":4,"mouth":6,"cheek":3,"frame":690},
            {"leye":2,"reye":4,"mouth":3,"cheek":3,"frame":692},
            {"leye":2,"reye":4,"mouth":9,"cheek":3,"frame":693},
            {"leye":2,"reye":4,"mouth":12,"cheek":3,"frame":694},
            {"leye":2,"reye":4,"mouth":17,"cheek":3,"frame":695},
            {"leye":2,"reye":4,"mouth":12,"cheek":3,"frame":696},
            {"leye":2,"reye":4,"mouth":17,"cheek":3,"frame":699},
            {"leye":2,"reye":4,"mouth":6,"cheek":3,"frame":700},
            {"leye":5,"reye":5,"mouth":9,"cheek":0,"frame":707},
            {"leye":5,"reye":5,"mouth":17,"cheek":0,"frame":708},
            {"leye":5,"reye":5,"mouth":10,"cheek":0,"frame":709},
            {"leye":5,"reye":5,"mouth":12,"cheek":0,"frame":712},
            {"leye":5,"reye":5,"mouth":17,"cheek":0,"frame":713},
            {"leye":5,"reye":5,"mouth":9,"cheek":0,"frame":714},
            {"leye":5,"reye":5,"mouth":6,"cheek":0,"frame":715},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":720},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":722},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":723},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":726},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":727},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":728},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":733},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":734},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":735},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":737},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":738},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":739},
            {"leye":4,"reye":4,"mouth":9,"cheek":3,"frame":741},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":742},
            {"leye":4,"reye":4,"mouth":12,"cheek":3,"frame":743},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":744},
            {"leye":4,"reye":4,"mouth":9,"cheek":3,"frame":748},
            {"leye":4,"reye":4,"mouth":12,"cheek":3,"frame":749},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":750},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":752},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":754},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":755},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":756},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":757},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":759},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":761},
            {"leye":6,"reye":6,"mouth":9,"cheek":3,"frame":762},
            {"leye":6,"reye":6,"mouth":6,"cheek":3,"frame":763},
            {"leye":6,"reye":6,"mouth":9,"cheek":3,"frame":767},
            {"leye":6,"reye":6,"mouth":6,"cheek":3,"frame":768},
            {"leye":6,"reye":6,"mouth":12,"cheek":3,"frame":771},
            {"leye":2,"reye":2,"mouth":6,"cheek":2,"frame":772},
            {"leye":2,"reye":2,"mouth":12,"cheek":2,"frame":773},
            {"leye":2,"reye":2,"mouth":6,"cheek":2,"frame":774},
            {"leye":2,"reye":2,"mouth":12,"cheek":2,"frame":776},
            {"leye":2,"reye":2,"mouth":6,"cheek":2,"frame":777},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":782},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":783},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":784},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":785},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":789},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":790},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":791},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":792},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":793},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":794},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":801},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":802},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":807},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":808},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":809},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":810},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":811},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":813},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":814},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":816},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":817},
            {"leye":19,"reye":19,"mouth":6,"cheek":3,"frame":818},
            {"leye":19,"reye":19,"mouth":9,"cheek":3,"frame":823},
            {"leye":19,"reye":19,"mouth":17,"cheek":3,"frame":825},
            {"leye":19,"reye":19,"mouth":12,"cheek":3,"frame":826},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":827},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":829},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":830},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":833},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":834},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":837},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":838},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":842},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":845},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":848},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":849},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":850},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":851},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":852},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":853},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":854},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":855},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":856},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":857},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":860},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":861},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":862},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":863},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":880},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":881},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":882},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":884},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":885},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":888},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":889},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":892},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":893},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":895},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":899},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":900},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":903},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":904},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":908},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":909},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":910},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":926},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":927},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":939},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":940},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":942},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":943},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":946},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":947},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":950},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":952},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":955},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":956},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":957},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":958},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":959},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":960},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":962},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":964},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":965},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":966},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":967},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":970},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":973},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":974},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":976},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":977},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":979},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":981},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":982},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":983},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":985},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":986},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":989},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":991},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":996},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":997},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1001},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1002},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1003},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1004},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1005},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1006},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1009},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1010},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1012},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1015},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1017},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1019},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1022},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1023},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1024},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1025},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1026},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1027},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1028},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1029},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1032},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1033},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1034},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1038},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1044},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1045},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1047},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1048},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1050},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1052},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1055},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1056},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1058},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1059},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1063},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1065},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1067},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1068},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1069},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1072},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1073},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1076},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1077},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1078},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1081},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1082},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1085},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1086},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1087},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1091},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1092},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1093},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1094},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1095},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1099},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1100},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1103},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1104},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1105},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1106},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1108},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1109},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1110},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1113},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1114},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1119},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1122},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1124},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1125},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1127},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1128},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1129},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1130},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1131},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1132},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1135},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1136},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1137},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1139},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1140},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1143},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1144},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1145},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1146},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1147},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1148},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1149},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1150},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1152},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1157},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1158},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1162},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1163},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1164},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1165},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1166},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1168},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1172},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1174},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1175},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1177},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1178},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1181},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1185},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1188},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1189},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1191},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1201},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1202},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1207},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1208},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1210},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1211},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1212},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1213},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1216},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1217},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1218},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1220},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1224},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1226},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1228},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1229},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1231},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1232},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1233},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1234},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1238},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1239},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1240},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1241},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1242},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1243},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1245},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1248},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1249},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1258},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1259},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1261},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1264},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1269},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1270},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1271},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1272},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1280},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1284},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1285},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1287},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1288},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1291},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1293},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1294},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1296},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1297},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1298},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1299},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1303},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1304},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1306},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1308},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1310},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1311},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1313},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1314},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1315},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1316},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1317},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1318},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1320},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1322},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1323},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1327},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1328},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1329},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1334},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1335},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1337},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1338},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1343},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1346},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1347},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1351},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1352},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1353},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1354},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1355},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1357},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1358},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1360},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1361},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1363},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1364},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1366},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1370},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1372},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1374},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1375},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1376},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1377},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1380},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1381},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1386},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1390},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1391},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1393},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1394},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1395},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1396},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1397},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1404},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1405},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1406},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1407},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1411},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1412},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1413},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1417},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1419},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1421},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1424},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1425},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1426},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1427},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1430},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1433},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1434},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1435},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1436},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1437},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1439},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1442},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1443},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1444},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1448},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1449},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1450},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1455},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1456},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1460},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1461},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1462},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1464},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1468},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1469},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1471},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1473},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1475},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1476},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1480},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1481},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1482},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1483},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1484},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1485},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1486},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1487},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1488},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1489},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1490},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1491},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1492},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1498},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1499},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1502},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1504},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1507},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1509},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1515},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1516},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1518},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1519},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1521},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1525},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1623},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1626},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1628},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1629},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1638},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1646},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1647},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1648},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1650},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1651},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1652},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1654},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1655},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1656},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1659},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1660},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1661},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1662},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1665},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1666},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1667},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1669},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1676},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1678},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1679},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1680},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1683},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1684},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1685},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1686},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1687},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1689},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1690},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1695},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1696},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1699},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1700},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1701},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1705},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1706},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1707},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1708},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1710},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1711},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1720},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1721},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1723},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1724},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1726},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1728},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1729},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1730},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1731},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1732},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1733},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1736},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1737},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1760},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1761},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1763},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1766},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1769},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1771},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1779},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1780},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1783},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1784},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1801},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1835},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1836},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1837},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1839},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1842},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1843},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1844},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1845},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1846},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1847},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1852},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1855},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1857},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1860},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1861},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1862},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1863},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1864},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1865},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1867},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1868},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1870},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1872},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1873},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1874},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1876},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1877},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1878},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1879},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1883},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1885},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1887},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1889},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1891},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1892},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1894},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1901},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1902},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1903},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1904},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1905},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1909},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1910},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1911},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1913},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1914},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1915},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":1917},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1918},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1923},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1925},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1926},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1928},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1933},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1934},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1938},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1940},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1942},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1946},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1947},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1948},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1949},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1950},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1953},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1954},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1956},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1957},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1958},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1961},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1963},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1966},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1967},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1970},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1972},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1973},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1978},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1981},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1982},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1983},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1985},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1988},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":1989},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1990},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1991},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":1995},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":1997},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":1999},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2000},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2002},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2003},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2004},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2014},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2015},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":2018},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2019},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2021},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2023},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2024},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2028},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2030},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2034},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2035},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2040},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2041},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2042},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2043},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":2044},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2045},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":2046},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2047},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2051},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2052},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2053},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2054},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2057},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2058},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":2060},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2061},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2063},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2064},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2068},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2069},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2072},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2073},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2074},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2076},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":2077},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2078},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2079},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2085},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2087},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2094},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2095},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2100},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2101},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2104},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2106},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":2108},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2112},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2114},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2115},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2116},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2117},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2119},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2124},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2125},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2133},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2134},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2138},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2139},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2142},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2143},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2146},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2147},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2151},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2152},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2155},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2157},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2158},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2159},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2160},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2163},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2164},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2165},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2167},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":2168},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2169},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":2171},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2172},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2179},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2181},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2193},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2194},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2198},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":2199},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":2205},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":2207},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":2310},
        ]
    },
    {
        id:'music_02_09_04_00_0',
        name:'相连的Connect(Short ver.)',
        cover_src:'https://www.738ngx.site/api/rinachanboard/images/cover/music_02_09_04.png',
        music_src:'https://www.738ngx.site/api/rinachanboard/musics/music_02_09_04_0.mp3',
        singer:'天王寺璃奈(田中ちえ美)',
        text:  'ツナガルコネクト是《LoveLive!虹咲学园学园偶像同好会》动画第一季第六集的插入曲，由天王寺璃奈演唱。歌曲收录于动画第一季第二张插入曲单曲《サイコーハート / La Bella Patria / ツナガルコネクト》中，发售于2020年12月2日。',
        faces:[
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":0},
            {"leye":6,"reye":6,"mouth":3,"cheek":0,"frame":30},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":32},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":35},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":36},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":37},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":39},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":41},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":44},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":45},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":46},
            {"leye":4,"reye":4,"mouth":3,"cheek":3,"frame":47},
            {"leye":4,"reye":4,"mouth":9,"cheek":3,"frame":48},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":49},
            {"leye":4,"reye":4,"mouth":12,"cheek":3,"frame":50},
            {"leye":4,"reye":4,"mouth":17,"cheek":3,"frame":51},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":52},
            {"leye":4,"reye":4,"mouth":3,"cheek":3,"frame":54},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":55},
            {"leye":2,"reye":2,"mouth":6,"cheek":2,"frame":62},
            {"leye":2,"reye":2,"mouth":12,"cheek":2,"frame":66},
            {"leye":2,"reye":2,"mouth":6,"cheek":2,"frame":67},
            {"leye":1,"reye":1,"mouth":9,"cheek":2,"frame":71},
            {"leye":1,"reye":1,"mouth":17,"cheek":2,"frame":72},
            {"leye":1,"reye":1,"mouth":6,"cheek":2,"frame":73},
            {"leye":1,"reye":1,"mouth":9,"cheek":2,"frame":76},
            {"leye":1,"reye":1,"mouth":6,"cheek":2,"frame":77},
            {"leye":1,"reye":1,"mouth":9,"cheek":2,"frame":83},
            {"leye":19,"reye":19,"mouth":10,"cheek":3,"frame":85},
            {"leye":19,"reye":19,"mouth":6,"cheek":3,"frame":86},
            {"leye":19,"reye":19,"mouth":12,"cheek":3,"frame":88},
            {"leye":2,"reye":2,"mouth":6,"cheek":2,"frame":90},
            {"leye":2,"reye":2,"mouth":12,"cheek":2,"frame":92},
            {"leye":4,"reye":4,"mouth":6,"cheek":2,"frame":94},
            {"leye":4,"reye":4,"mouth":12,"cheek":2,"frame":95},
            {"leye":4,"reye":4,"mouth":6,"cheek":2,"frame":96},
            {"leye":4,"reye":4,"mouth":12,"cheek":2,"frame":97},
            {"leye":4,"reye":4,"mouth":6,"cheek":2,"frame":98},
            {"leye":4,"reye":4,"mouth":17,"cheek":2,"frame":103},
            {"leye":4,"reye":4,"mouth":6,"cheek":2,"frame":104},
            {"leye":4,"reye":4,"mouth":10,"cheek":2,"frame":107},
            {"leye":4,"reye":4,"mouth":17,"cheek":2,"frame":109},
            {"leye":1,"reye":1,"mouth":6,"cheek":2,"frame":111},
            {"leye":1,"reye":1,"mouth":10,"cheek":2,"frame":112},
            {"leye":1,"reye":1,"mouth":17,"cheek":2,"frame":114},
            {"leye":1,"reye":1,"mouth":6,"cheek":2,"frame":115},
            {"leye":1,"reye":1,"mouth":12,"cheek":2,"frame":121},
            {"leye":1,"reye":1,"mouth":6,"cheek":2,"frame":123},
            {"leye":1,"reye":1,"mouth":9,"cheek":2,"frame":131},
            {"leye":19,"reye":19,"mouth":6,"cheek":2,"frame":132},
            {"leye":19,"reye":19,"mouth":17,"cheek":2,"frame":140},
            {"leye":19,"reye":19,"mouth":6,"cheek":2,"frame":141},
            {"leye":2,"reye":2,"mouth":17,"cheek":2,"frame":144},
            {"leye":2,"reye":2,"mouth":6,"cheek":2,"frame":145},
            {"leye":2,"reye":2,"mouth":17,"cheek":2,"frame":147},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":149},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":153},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":154},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":155},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":157},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":159},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":161},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":162},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":163},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":165},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":166},
            {"leye":4,"reye":4,"mouth":17,"cheek":0,"frame":167},
            {"leye":4,"reye":4,"mouth":9,"cheek":0,"frame":168},
            {"leye":4,"reye":4,"mouth":6,"cheek":0,"frame":170},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":198},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":202},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":204},
            {"leye":6,"reye":6,"mouth":3,"cheek":0,"frame":206},
            {"leye":5,"reye":5,"mouth":6,"cheek":0,"frame":207},
            {"leye":5,"reye":5,"mouth":12,"cheek":0,"frame":209},
            {"leye":5,"reye":5,"mouth":6,"cheek":0,"frame":210},
            {"leye":5,"reye":5,"mouth":12,"cheek":0,"frame":211},
            {"leye":5,"reye":5,"mouth":6,"cheek":0,"frame":213},
            {"leye":5,"reye":5,"mouth":12,"cheek":0,"frame":214},
            {"leye":5,"reye":5,"mouth":17,"cheek":0,"frame":217},
            {"leye":5,"reye":5,"mouth":6,"cheek":0,"frame":218},
            {"leye":4,"reye":4,"mouth":17,"cheek":0,"frame":219},
            {"leye":4,"reye":4,"mouth":9,"cheek":0,"frame":220},
            {"leye":4,"reye":4,"mouth":10,"cheek":0,"frame":221},
            {"leye":4,"reye":4,"mouth":17,"cheek":0,"frame":224},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":225},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":229},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":230},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":233},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":238},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":240},
            {"leye":6,"reye":6,"mouth":17,"cheek":0,"frame":242},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":243},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":244},
            {"leye":6,"reye":6,"mouth":15,"cheek":0,"frame":247},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":252},
            {"leye":5,"reye":5,"mouth":12,"cheek":0,"frame":255},
            {"leye":4,"reye":4,"mouth":6,"cheek":0,"frame":257},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":259},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":260},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":264},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":265},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":266},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":268},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":269},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":272},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":273},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":275},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":276},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":278},
            {"leye":6,"reye":6,"mouth":10,"cheek":0,"frame":279},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":280},
            {"leye":5,"reye":17,"mouth":12,"cheek":0,"frame":281},
            {"leye":5,"reye":17,"mouth":9,"cheek":0,"frame":287},
            {"leye":5,"reye":17,"mouth":6,"cheek":0,"frame":288},
            {"leye":5,"reye":17,"mouth":12,"cheek":0,"frame":289},
            {"leye":5,"reye":17,"mouth":6,"cheek":0,"frame":293},
            {"leye":5,"reye":17,"mouth":12,"cheek":0,"frame":295},
            {"leye":5,"reye":17,"mouth":17,"cheek":0,"frame":296},
            {"leye":5,"reye":17,"mouth":6,"cheek":0,"frame":297},
            {"leye":5,"reye":17,"mouth":12,"cheek":0,"frame":301},
            {"leye":5,"reye":17,"mouth":6,"cheek":0,"frame":302},
            {"leye":5,"reye":17,"mouth":12,"cheek":0,"frame":306},
            {"leye":4,"reye":4,"mouth":6,"cheek":0,"frame":307},
            {"leye":4,"reye":4,"mouth":12,"cheek":0,"frame":309},
            {"leye":4,"reye":4,"mouth":10,"cheek":0,"frame":310},
            {"leye":4,"reye":4,"mouth":6,"cheek":0,"frame":311},
            {"leye":4,"reye":4,"mouth":9,"cheek":0,"frame":312},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":314},
            {"leye":6,"reye":6,"mouth":17,"cheek":0,"frame":315},
            {"leye":5,"reye":17,"mouth":9,"cheek":0,"frame":316},
            {"leye":5,"reye":17,"mouth":6,"cheek":0,"frame":317},
            {"leye":5,"reye":17,"mouth":9,"cheek":0,"frame":318},
            {"leye":5,"reye":17,"mouth":10,"cheek":0,"frame":319},
            {"leye":5,"reye":17,"mouth":9,"cheek":0,"frame":320},
            {"leye":5,"reye":17,"mouth":6,"cheek":0,"frame":321},
            {"leye":5,"reye":17,"mouth":9,"cheek":0,"frame":322},
            {"leye":5,"reye":17,"mouth":12,"cheek":0,"frame":323},
            {"leye":5,"reye":17,"mouth":6,"cheek":0,"frame":327},
            {"leye":5,"reye":17,"mouth":9,"cheek":0,"frame":328},
            {"leye":9,"reye":10,"mouth":6,"cheek":0,"frame":329},
            {"leye":9,"reye":10,"mouth":17,"cheek":0,"frame":334},
            {"leye":9,"reye":10,"mouth":12,"cheek":0,"frame":336},
            {"leye":9,"reye":10,"mouth":9,"cheek":0,"frame":340},
            {"leye":9,"reye":10,"mouth":6,"cheek":0,"frame":341},
            {"leye":9,"reye":10,"mouth":12,"cheek":0,"frame":342},
            {"leye":9,"reye":10,"mouth":17,"cheek":0,"frame":344},
            {"leye":9,"reye":10,"mouth":6,"cheek":0,"frame":348},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":349},
            {"leye":6,"reye":6,"mouth":9,"cheek":0,"frame":350},
            {"leye":4,"reye":4,"mouth":17,"cheek":3,"frame":351},
            {"leye":4,"reye":4,"mouth":9,"cheek":3,"frame":353},
            {"leye":4,"reye":4,"mouth":17,"cheek":3,"frame":354},
            {"leye":4,"reye":4,"mouth":12,"cheek":3,"frame":355},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":356},
            {"leye":4,"reye":4,"mouth":9,"cheek":3,"frame":360},
            {"leye":4,"reye":4,"mouth":17,"cheek":3,"frame":361},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":362},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":363},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":364},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":365},
            {"leye":6,"reye":6,"mouth":3,"cheek":0,"frame":368},
            {"leye":11,"reye":11,"mouth":6,"cheek":0,"frame":369},
            {"leye":11,"reye":11,"mouth":12,"cheek":0,"frame":371},
            {"leye":11,"reye":11,"mouth":6,"cheek":0,"frame":372},
            {"leye":11,"reye":11,"mouth":12,"cheek":0,"frame":377},
            {"leye":11,"reye":11,"mouth":6,"cheek":0,"frame":379},
            {"leye":11,"reye":11,"mouth":9,"cheek":2,"frame":381},
            {"leye":11,"reye":11,"mouth":6,"cheek":2,"frame":382},
            {"leye":11,"reye":11,"mouth":12,"cheek":2,"frame":385},
            {"leye":11,"reye":11,"mouth":6,"cheek":2,"frame":386},
            {"leye":11,"reye":11,"mouth":10,"cheek":2,"frame":387},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":389},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":390},
            {"leye":19,"reye":19,"mouth":17,"cheek":0,"frame":392},
            {"leye":19,"reye":19,"mouth":6,"cheek":0,"frame":395},
            {"leye":19,"reye":19,"mouth":12,"cheek":0,"frame":396},
            {"leye":19,"reye":19,"mouth":6,"cheek":0,"frame":401},
            {"leye":5,"reye":5,"mouth":12,"cheek":0,"frame":404},
            {"leye":5,"reye":5,"mouth":9,"cheek":0,"frame":405},
            {"leye":5,"reye":5,"mouth":6,"cheek":0,"frame":406},
            {"leye":5,"reye":5,"mouth":17,"cheek":0,"frame":407},
            {"leye":5,"reye":5,"mouth":6,"cheek":0,"frame":408},
            {"leye":5,"reye":5,"mouth":17,"cheek":0,"frame":409},
            {"leye":5,"reye":5,"mouth":10,"cheek":0,"frame":410},
            {"leye":5,"reye":5,"mouth":12,"cheek":0,"frame":411},
            {"leye":7,"reye":8,"mouth":6,"cheek":0,"frame":412},
            {"leye":7,"reye":8,"mouth":3,"cheek":0,"frame":414},
            {"leye":7,"reye":8,"mouth":6,"cheek":0,"frame":415},
            {"leye":4,"reye":2,"mouth":17,"cheek":0,"frame":424},
            {"leye":4,"reye":2,"mouth":6,"cheek":0,"frame":425},
            {"leye":4,"reye":2,"mouth":12,"cheek":0,"frame":427},
            {"leye":4,"reye":2,"mouth":6,"cheek":0,"frame":428},
            {"leye":2,"reye":4,"mouth":12,"cheek":0,"frame":430},
            {"leye":2,"reye":4,"mouth":17,"cheek":0,"frame":431},
            {"leye":2,"reye":4,"mouth":6,"cheek":0,"frame":433},
            {"leye":2,"reye":4,"mouth":17,"cheek":0,"frame":435},
            {"leye":2,"reye":4,"mouth":6,"cheek":0,"frame":436},
            {"leye":2,"reye":4,"mouth":12,"cheek":0,"frame":439},
            {"leye":2,"reye":4,"mouth":9,"cheek":0,"frame":441},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":442},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":444},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":445},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":447},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":449},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":451},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":452},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":454},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":456},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":457},
            {"leye":6,"reye":6,"mouth":17,"cheek":0,"frame":458},
            {"leye":6,"reye":6,"mouth":9,"cheek":0,"frame":460},
            {"leye":6,"reye":6,"mouth":17,"cheek":0,"frame":461},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":462},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":463},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":464},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":466},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":467},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":470},
            {"leye":2,"reye":2,"mouth":6,"cheek":3,"frame":471},
            {"leye":2,"reye":2,"mouth":12,"cheek":3,"frame":472},
            {"leye":2,"reye":2,"mouth":6,"cheek":3,"frame":473},
            {"leye":2,"reye":2,"mouth":9,"cheek":3,"frame":474},
            {"leye":2,"reye":2,"mouth":6,"cheek":3,"frame":475},
            {"leye":2,"reye":2,"mouth":17,"cheek":3,"frame":476},
            {"leye":2,"reye":2,"mouth":12,"cheek":3,"frame":480},
            {"leye":2,"reye":2,"mouth":9,"cheek":3,"frame":481},
            {"leye":2,"reye":2,"mouth":6,"cheek":3,"frame":482},
            {"leye":2,"reye":2,"mouth":9,"cheek":3,"frame":484},
            {"leye":2,"reye":2,"mouth":6,"cheek":3,"frame":488},
            {"leye":2,"reye":2,"mouth":9,"cheek":3,"frame":492},
            {"leye":2,"reye":2,"mouth":6,"cheek":3,"frame":494},
            {"leye":2,"reye":2,"mouth":9,"cheek":3,"frame":516},
            {"leye":2,"reye":2,"mouth":17,"cheek":3,"frame":517},
            {"leye":2,"reye":2,"mouth":6,"cheek":3,"frame":518},
            {"leye":2,"reye":2,"mouth":17,"cheek":3,"frame":520},
            {"leye":4,"reye":4,"mouth":12,"cheek":0,"frame":522},
            {"leye":4,"reye":4,"mouth":6,"cheek":0,"frame":525},
            {"leye":4,"reye":4,"mouth":3,"cheek":0,"frame":528},
            {"leye":4,"reye":4,"mouth":9,"cheek":0,"frame":529},
            {"leye":4,"reye":4,"mouth":6,"cheek":0,"frame":530},
            {"leye":4,"reye":4,"mouth":12,"cheek":0,"frame":544},
            {"leye":4,"reye":4,"mouth":6,"cheek":0,"frame":545},
            {"leye":4,"reye":4,"mouth":12,"cheek":0,"frame":546},
            {"leye":4,"reye":4,"mouth":9,"cheek":0,"frame":550},
            {"leye":4,"reye":4,"mouth":3,"cheek":0,"frame":552},
            {"leye":4,"reye":4,"mouth":17,"cheek":0,"frame":554},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":555},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":556},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":558},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":559},
            {"leye":4,"reye":4,"mouth":9,"cheek":2,"frame":563},
            {"leye":4,"reye":4,"mouth":6,"cheek":2,"frame":564},
            {"leye":4,"reye":4,"mouth":12,"cheek":2,"frame":565},
            {"leye":4,"reye":4,"mouth":6,"cheek":2,"frame":566},
            {"leye":4,"reye":4,"mouth":9,"cheek":2,"frame":568},
            {"leye":4,"reye":4,"mouth":6,"cheek":2,"frame":569},
            {"leye":1,"reye":1,"mouth":12,"cheek":3,"frame":570},
            {"leye":1,"reye":1,"mouth":6,"cheek":3,"frame":572},
            {"leye":1,"reye":1,"mouth":12,"cheek":3,"frame":573},
            {"leye":1,"reye":1,"mouth":6,"cheek":3,"frame":575},
            {"leye":4,"reye":4,"mouth":17,"cheek":3,"frame":578},
            {"leye":4,"reye":4,"mouth":3,"cheek":3,"frame":580},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":581},
            {"leye":4,"reye":4,"mouth":12,"cheek":3,"frame":582},
            {"leye":4,"reye":4,"mouth":17,"cheek":0,"frame":584},
            {"leye":2,"reye":2,"mouth":12,"cheek":0,"frame":586},
            {"leye":2,"reye":2,"mouth":6,"cheek":0,"frame":588},
            {"leye":2,"reye":2,"mouth":17,"cheek":0,"frame":589},
            {"leye":2,"reye":2,"mouth":6,"cheek":0,"frame":594},
            {"leye":2,"reye":2,"mouth":9,"cheek":0,"frame":596},
            {"leye":6,"reye":6,"mouth":10,"cheek":0,"frame":599},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":602},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":603},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":605},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":606},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":608},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":609},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":611},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":613},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":615},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":616},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":617},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":618},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":624},
            {"leye":6,"reye":6,"mouth":12,"cheek":0,"frame":626},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":628},
            {"leye":6,"reye":6,"mouth":17,"cheek":0,"frame":629},
            {"leye":6,"reye":6,"mouth":9,"cheek":0,"frame":630},
            {"leye":6,"reye":6,"mouth":17,"cheek":0,"frame":632},
            {"leye":6,"reye":6,"mouth":6,"cheek":0,"frame":633},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":636},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":637},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":638},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":639},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":641},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":642},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":644},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":646},
            {"leye":4,"reye":2,"mouth":6,"cheek":3,"frame":648},
            {"leye":4,"reye":2,"mouth":9,"cheek":3,"frame":649},
            {"leye":4,"reye":2,"mouth":17,"cheek":3,"frame":650},
            {"leye":4,"reye":2,"mouth":6,"cheek":3,"frame":651},
            {"leye":4,"reye":2,"mouth":17,"cheek":3,"frame":653},
            {"leye":4,"reye":2,"mouth":10,"cheek":3,"frame":654},
            {"leye":4,"reye":2,"mouth":6,"cheek":3,"frame":656},
            {"leye":5,"reye":5,"mouth":12,"cheek":3,"frame":662},
            {"leye":5,"reye":5,"mouth":6,"cheek":3,"frame":663},
            {"leye":5,"reye":5,"0mouth":3,"cheek":3,"frame":664},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":665},
            {"leye":4,"reye":4,"mouth":17,"cheek":3,"frame":666},
            {"leye":4,"reye":4,"mouth":10,"cheek":3,"frame":670},
            {"leye":4,"reye":4,"mouth":9,"cheek":3,"frame":671},
            {"leye":4,"reye":4,"mouth":17,"cheek":3,"frame":672},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":676},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":678},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":679},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":680},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":684},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":685},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":686},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":687},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":688},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":689},
            {"leye":2,"reye":4,"mouth":6,"cheek":3,"frame":690},
            {"leye":2,"reye":4,"mouth":3,"cheek":3,"frame":692},
            {"leye":2,"reye":4,"mouth":9,"cheek":3,"frame":693},
            {"leye":2,"reye":4,"mouth":12,"cheek":3,"frame":694},
            {"leye":2,"reye":4,"mouth":17,"cheek":3,"frame":695},
            {"leye":2,"reye":4,"mouth":12,"cheek":3,"frame":696},
            {"leye":2,"reye":4,"mouth":17,"cheek":3,"frame":699},
            {"leye":2,"reye":4,"mouth":6,"cheek":3,"frame":700},
            {"leye":5,"reye":5,"mouth":9,"cheek":0,"frame":707},
            {"leye":5,"reye":5,"mouth":17,"cheek":0,"frame":708},
            {"leye":5,"reye":5,"mouth":10,"cheek":0,"frame":709},
            {"leye":5,"reye":5,"mouth":12,"cheek":0,"frame":712},
            {"leye":5,"reye":5,"mouth":17,"cheek":0,"frame":713},
            {"leye":5,"reye":5,"mouth":9,"cheek":0,"frame":714},
            {"leye":5,"reye":5,"mouth":6,"cheek":0,"frame":715},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":720},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":722},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":723},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":726},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":727},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":728},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":733},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":734},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":735},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":737},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":738},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":739},
            {"leye":4,"reye":4,"mouth":9,"cheek":3,"frame":741},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":742},
            {"leye":4,"reye":4,"mouth":12,"cheek":3,"frame":743},
            {"leye":4,"reye":4,"mouth":6,"cheek":3,"frame":744},
            {"leye":4,"reye":4,"mouth":9,"cheek":3,"frame":748},
            {"leye":4,"reye":4,"mouth":12,"cheek":3,"frame":749},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":750},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":752},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":754},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":755},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":756},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":757},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":759},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":761},
            {"leye":6,"reye":6,"mouth":9,"cheek":3,"frame":762},
            {"leye":6,"reye":6,"mouth":6,"cheek":3,"frame":763},
            {"leye":6,"reye":6,"mouth":9,"cheek":3,"frame":767},
            {"leye":6,"reye":6,"mouth":6,"cheek":3,"frame":768},
            {"leye":6,"reye":6,"mouth":12,"cheek":3,"frame":771},
            {"leye":2,"reye":2,"mouth":6,"cheek":2,"frame":772},
            {"leye":2,"reye":2,"mouth":12,"cheek":2,"frame":773},
            {"leye":2,"reye":2,"mouth":6,"cheek":2,"frame":774},
            {"leye":2,"reye":2,"mouth":12,"cheek":2,"frame":776},
            {"leye":2,"reye":2,"mouth":6,"cheek":2,"frame":777},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":782},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":783},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":784},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":785},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":789},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":790},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":791},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":792},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":793},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":794},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":801},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":802},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":807},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":808},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":809},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":810},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":811},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":813},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":814},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":816},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":817},
            {"leye":19,"reye":19,"mouth":6,"cheek":3,"frame":818},
            {"leye":19,"reye":19,"mouth":9,"cheek":3,"frame":823},
            {"leye":19,"reye":19,"mouth":17,"cheek":3,"frame":825},
            {"leye":19,"reye":19,"mouth":12,"cheek":3,"frame":826},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":827},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":829},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":830},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":833},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":834},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":837},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":838},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":842},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":845},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":848},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":849},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":850},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":851},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":852},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":853},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":854},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":855},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":856},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":857},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":860},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":861},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":862},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":863},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":880},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":881},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":882},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":884},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":885},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":888},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":889},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":892},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":893},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":895},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":899},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":900},
            {"leye":1,"reye":1,"mouth":10,"cheek":0,"frame":903},
            {"leye":1,"reye":1,"mouth":17,"cheek":0,"frame":904},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":908},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":909},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":910},
            {"leye":1,"reye":1,"mouth":9,"cheek":0,"frame":926},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":927},
            {"leye":1,"reye":1,"mouth":12,"cheek":0,"frame":939},
            {"leye":1,"reye":1,"mouth":6,"cheek":0,"frame":940},
            {"leye":2,"reye":2,"mouth":4,"cheek":2,"frame":940},
            {"leye":1,"reye":1,"mouth":3,"cheek":0,"frame":1019},
        ]
    },
    {
        id:'music_02_00_02_09_0',
        name:'Love U my friends(Short ver.)',
        cover_src:'https://www.738ngx.site/api/rinachanboard/images/cover/music_02_00_02.png',
        music_src:'https://www.738ngx.site/api/rinachanboard/musics/music_02_00_02_0.mp3',
        singer:'虹ヶ咲学園スクールアイドル同好会',
        text:  'Love U my friends是虹咲学园学园偶像同好会第二张专辑《Love U my friends》中收录的同名歌曲，由虹咲学园学园偶像同好会演唱，发售于2019年10月2日。',
        faces:[
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame:   0},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame:  69},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame: 112},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 117},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame: 127},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 131},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame: 141},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 146},
            {leye: 6,reye: 6,mouth: 5,cheek: 0,frame: 160},
            {leye: 1,reye: 1,mouth: 5,cheek: 0,frame: 164},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 168},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,frame: 186},
            {leye: 1,reye: 4,mouth: 3,cheek: 2,frame: 193},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,frame: 196},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 200},
            {leye: 1,reye: 1,mouth: 5,cheek: 0,frame: 202},
            {leye: 1,reye: 1,mouth:10,cheek: 0,frame: 204},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 207},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 208},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 212},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 214},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 216},
            {leye: 1,reye: 1,mouth:10,cheek: 0,frame: 218},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 221},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 223},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 226},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 228},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 230},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 234},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 238},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 245},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 249},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 261},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 271},
            {leye: 1,reye: 1,mouth:10,cheek: 0,frame: 275},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 277},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 279},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 283},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 284},
            {leye: 2,reye: 2,mouth: 9,cheek: 0,frame: 302},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,frame: 304},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame: 306},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,frame: 308},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 314},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame: 317},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 334},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 401},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 404},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 407},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 411},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 413},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 415},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 417},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 418},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 422},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 425},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame: 432},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 437},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame: 439},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 444},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 488},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 489},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 491},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 492},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 493},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 497},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 501},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 503},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 505},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 506},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 507},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 514},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame: 524},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 532},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 533},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 535},
            {leye: 6,reye: 6,mouth: 7,cheek: 0,frame: 537},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 539},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 545},
            {leye: 4,reye: 4,mouth: 3,cheek: 2,frame: 554},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame: 558},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,frame: 563},
            {leye: 2,reye: 2,mouth: 6,cheek: 0,frame: 566},
            {leye: 2,reye: 2,mouth: 9,cheek: 0,frame: 568},
            {leye: 2,reye: 2,mouth: 6,cheek: 0,frame: 570},
            {leye: 2,reye: 2,mouth: 9,cheek: 0,frame: 571},
            {leye: 2,reye: 2,mouth:10,cheek: 0,frame: 574},
            {leye: 2,reye: 2,mouth: 6,cheek: 0,frame: 578},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 580},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 588},
            {leye: 1,reye: 1,mouth: 5,cheek: 0,frame: 592},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 594},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 597},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 602},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 604},
            {leye: 1,reye: 1,mouth:10,cheek: 0,frame: 610},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 612},
            {leye: 1,reye: 1,mouth:10,cheek: 0,frame: 614},
            {leye: 1,reye: 1,mouth: 5,cheek: 0,frame: 620},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 626},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 629},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 634},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 637},
            {leye: 1,reye: 1,mouth:10,cheek: 0,frame: 644},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 646},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 655},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 657},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 658},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 661},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 669},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 671},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 682},
            {leye: 1,reye: 1,mouth:10,cheek: 0,frame: 684},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 686},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 688},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 694},
            {leye: 1,reye: 1,mouth:10,cheek: 0,frame: 702},
            {leye: 1,reye: 1,mouth: 5,cheek: 0,frame: 705},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 707},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 709},
            {leye: 1,reye: 1,mouth:10,cheek: 0,frame: 711},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 713},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 714},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 717},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 724},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 726},
            {leye: 1,reye: 1,mouth:10,cheek: 0,frame: 727},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 729},
            {leye: 1,reye: 1,mouth: 5,cheek: 0,frame: 735},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 737},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 740},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 743},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 746},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 751},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 756},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 757},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 760},
            {leye: 2,reye: 2,mouth: 6,cheek: 0,frame: 763},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame: 767},
            {leye: 6,reye: 6,mouth: 9,cheek: 0,frame: 769},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 773},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 776},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 778},
            {leye: 1,reye: 1,mouth:10,cheek: 0,frame: 786},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 791},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 794},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 820},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame: 823},
            {leye: 6,reye: 6,mouth: 5,cheek: 0,frame: 828},
            {leye: 6,reye: 6,mouth: 6,cheek: 0,frame: 829},
            {leye: 2,reye: 2,mouth: 6,cheek: 0,frame: 830},
            {leye: 2,reye: 2,mouth: 3,cheek: 0,frame: 831},
            {leye: 2,reye: 2,mouth:10,cheek: 0,frame: 832},
            {leye: 1,reye: 1,mouth:10,cheek: 0,frame: 833},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 834},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 835},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 836},
            {leye: 1,reye: 1,mouth: 9,cheek: 0,frame: 838},
            {leye: 1,reye: 1,mouth: 6,cheek: 0,frame: 839},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 842},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 866},
            {leye: 6,reye: 6,mouth: 7,cheek: 0,frame: 875},
            {leye: 1,reye: 1,mouth: 7,cheek: 0,frame: 881},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame: 889},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 895},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame: 937},
            {leye: 1,reye: 4,mouth: 3,cheek: 2,frame: 941},
            {leye: 1,reye: 1,mouth: 3,cheek: 0,frame: 946},
            {leye: 1,reye: 1,mouth:10,cheek: 0,frame: 978},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame:1023},
            {leye: 6,reye: 6,mouth: 3,cheek: 0,frame:1031},
        ]
    },
]

window.RINA_MUSIC_DATA = music_data;
// DATA_BUNDLE_END
// UNITY_DB_BEGIN
// ─── unity_db.js ───
window.RINA_UNITY_DB={"ascii":[{"id":32,"symbol":" ","content":[[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0]]},{"id":33,"symbol":"!","content":[[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,0,0,0],[0,0,1,0,0]]},{"id":34,"symbol":"\"","content":[[0,1,0,1,0],[0,1,0,1,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0]]},{"id":35,"symbol":"#","content":[[0,1,0,1,0],[0,1,0,1,0],[1,1,1,1,1],[0,1,0,1,0],[1,1,1,1,1],[0,1,0,1,0],[0,1,0,1,0]]},{"id":36,"symbol":"$","content":[[0,0,1,0,0],[0,1,1,1,1],[1,0,1,0,0],[0,1,1,1,0],[0,0,1,0,1],[1,1,1,1,0],[0,0,1,0,0]]},{"id":37,"symbol":"%","content":[[1,1,0,0,0],[1,1,0,0,1],[0,0,0,1,0],[0,0,1,0,0],[0,1,0,0,0],[1,0,0,1,1],[0,0,0,1,1]]},{"id":38,"symbol":"&","content":[[0,1,1,0,0],[1,0,0,1,0],[1,0,1,0,0],[0,1,0,0,0],[1,0,1,0,1],[1,0,0,1,0],[0,1,1,0,1]]},{"id":39,"symbol":"'","content":[[0,0,1,0,0],[0,0,1,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0]]},{"id":40,"symbol":"(","content":[[0,0,0,1,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,0,1,0]]},{"id":41,"symbol":")","content":[[0,1,0,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,1,0,0,0]]},{"id":42,"symbol":"*","content":[[0,0,0,0,0],[0,0,1,0,0],[1,0,1,0,1],[0,1,1,1,0],[1,0,1,0,1],[0,0,1,0,0],[0,0,0,0,0]]},{"id":43,"symbol":"+","content":[[0,0,0,0,0],[0,0,1,0,0],[0,0,1,0,0],[1,1,1,1,1],[0,0,1,0,0],[0,0,1,0,0],[0,0,0,0,0]]},{"id":44,"symbol":",","content":[[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,1,0,0],[0,1,0,0,0]]},{"id":45,"symbol":"-","content":[[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[1,1,1,1,1],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0]]},{"id":46,"symbol":".","content":[[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,1,0,0,0]]},{"id":47,"symbol":"/","content":[[0,0,0,0,1],[0,0,0,0,1],[0,0,0,1,0],[0,0,1,0,0],[0,1,0,0,0],[1,0,0,0,0],[1,0,0,0,0]]},{"id":48,"symbol":"0","content":[[0,1,1,1,0],[1,0,0,0,1],[1,1,0,0,1],[1,0,1,0,1],[1,0,0,1,1],[1,0,0,0,1],[0,1,1,1,0]]},{"id":49,"symbol":"1","content":[[0,0,1,0,0],[0,1,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,1,1,1,0]]},{"id":50,"symbol":"2","content":[[0,1,1,1,0],[1,0,0,0,1],[0,0,0,0,1],[0,0,0,1,0],[0,0,1,0,0],[0,1,0,0,0],[1,1,1,1,1]]},{"id":51,"symbol":"3","content":[[1,1,1,1,1],[0,0,0,0,1],[0,0,0,1,0],[0,0,1,1,0],[0,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]]},{"id":52,"symbol":"4","content":[[0,0,0,1,0],[0,0,1,1,0],[0,1,0,1,0],[1,0,0,1,0],[1,1,1,1,1],[0,0,0,1,0],[0,0,0,1,0]]},{"id":53,"symbol":"5","content":[[1,1,1,1,1],[1,0,0,0,0],[1,1,1,1,0],[0,0,0,0,1],[0,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]]},{"id":54,"symbol":"6","content":[[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,0],[1,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]]},{"id":55,"symbol":"7","content":[[1,1,1,1,1],[0,0,0,0,1],[0,0,0,1,0],[0,0,1,0,0],[0,1,0,0,0],[0,1,0,0,0],[0,1,0,0,0]]},{"id":56,"symbol":"8","content":[[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]]},{"id":57,"symbol":"9","content":[[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,1],[0,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]]},{"id":58,"symbol":":","content":[[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,1,0,0],[0,0,0,0,0],[0,0,1,0,0],[0,0,0,0,0]]},{"id":59,"symbol":";","content":[[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,1,0,0],[0,0,0,0,0],[0,0,1,0,0],[0,1,0,0,0]]},{"id":60,"symbol":"<","content":[[0,0,0,0,0],[0,0,0,1,0],[0,0,1,0,0],[0,1,0,0,0],[0,0,1,0,0],[0,0,0,1,0],[0,0,0,0,0]]},{"id":61,"symbol":"=","content":[[0,0,0,0,0],[0,0,0,0,0],[1,1,1,1,1],[0,0,0,0,0],[1,1,1,1,1],[0,0,0,0,0],[0,0,0,0,0]]},{"id":62,"symbol":">","content":[[0,0,0,0,0],[0,1,0,0,0],[0,0,1,0,0],[0,0,0,1,0],[0,0,1,0,0],[0,1,0,0,0],[0,0,0,0,0]]},{"id":63,"symbol":"?","content":[[0,1,1,1,0],[1,0,0,0,1],[0,0,0,0,1],[0,0,1,1,0],[0,0,1,0,0],[0,0,0,0,0],[0,0,1,0,0]]},{"id":64,"symbol":"@","content":[[0,1,1,1,0],[1,0,0,0,1],[1,0,1,1,1],[1,0,1,0,1],[1,0,1,1,1],[1,0,0,0,0],[0,1,1,1,0]]},{"id":65,"symbol":"A","content":[[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[1,1,1,1,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1]]},{"id":66,"symbol":"B","content":[[1,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[1,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[1,1,1,1,0]]},{"id":67,"symbol":"C","content":[[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,1],[0,1,1,1,0]]},{"id":68,"symbol":"D","content":[[1,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,1,1,1,0]]},{"id":69,"symbol":"E","content":[[1,1,1,1,1],[1,0,0,0,0],[1,0,0,0,0],[1,1,1,1,0],[1,0,0,0,0],[1,0,0,0,0],[1,1,1,1,1]]},{"id":70,"symbol":"F","content":[[1,1,1,1,1],[1,0,0,0,0],[1,0,0,0,0],[1,1,1,1,0],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0]]},{"id":71,"symbol":"G","content":[[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,0],[1,0,1,1,1],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]]},{"id":72,"symbol":"H","content":[[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,1,1,1,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1]]},{"id":73,"symbol":"I","content":[[0,1,1,1,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,1,1,1,0]]},{"id":74,"symbol":"J","content":[[0,1,1,1,1],[0,0,0,1,0],[0,0,0,1,0],[0,0,0,1,0],[0,0,0,1,0],[1,0,0,1,0],[0,1,1,0,0]]},{"id":75,"symbol":"K","content":[[1,0,0,0,1],[1,0,0,1,0],[1,0,1,0,0],[1,1,0,0,0],[1,0,1,0,0],[1,0,0,1,0],[1,0,0,0,1]]},{"id":76,"symbol":"L","content":[[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0],[1,1,1,1,1]]},{"id":77,"symbol":"M","content":[[1,0,0,0,1],[1,1,0,1,1],[1,0,1,0,1],[1,0,1,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1]]},{"id":78,"symbol":"N","content":[[1,0,0,0,1],[1,1,0,0,1],[1,0,1,0,1],[1,0,0,1,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1]]},{"id":79,"symbol":"O","content":[[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]]},{"id":80,"symbol":"P","content":[[1,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[1,1,1,1,0],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0]]},{"id":81,"symbol":"Q","content":[[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,1,0,1],[1,0,0,1,0],[0,1,1,0,1]]},{"id":82,"symbol":"R","content":[[1,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[1,1,1,1,0],[1,0,1,0,0],[1,0,0,1,0],[1,0,0,0,1]]},{"id":83,"symbol":"S","content":[[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,0],[0,1,1,1,0],[0,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]]},{"id":84,"symbol":"T","content":[[1,1,1,1,1],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0]]},{"id":85,"symbol":"U","content":[[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]]},{"id":86,"symbol":"V","content":[[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[0,1,0,1,0],[0,0,1,0,0]]},{"id":87,"symbol":"W","content":[[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,1,0,1],[1,0,1,0,1],[0,1,0,1,0]]},{"id":88,"symbol":"X","content":[[1,0,0,0,1],[1,0,0,0,1],[0,1,0,1,0],[0,0,1,0,0],[0,1,0,1,0],[1,0,0,0,1],[1,0,0,0,1]]},{"id":89,"symbol":"Y","content":[[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[0,1,0,1,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0]]},{"id":90,"symbol":"Z","content":[[1,1,1,1,1],[0,0,0,0,1],[0,0,0,1,0],[0,0,1,0,0],[0,1,0,0,0],[1,0,0,0,0],[1,1,1,1,1]]},{"id":91,"symbol":"[","content":[[0,0,1,1,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,1,0]]},{"id":92,"symbol":"\\","content":[[1,0,0,0,0],[1,0,0,0,0],[0,1,0,0,0],[0,0,1,0,0],[0,0,0,1,0],[0,0,0,0,1],[0,0,0,0,1]]},{"id":93,"symbol":"]","content":[[0,1,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,1,1,0,0]]},{"id":94,"symbol":"^","content":[[0,0,1,0,0],[0,1,0,1,0],[1,0,0,0,1],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0]]},{"id":95,"symbol":"_","content":[[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[1,1,1,1,1]]},{"id":96,"symbol":"`","content":[[0,0,1,0,0],[0,0,0,1,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0]]},{"id":97,"symbol":"a","content":[[0,0,0,0,0],[0,0,0,0,0],[0,1,1,1,0],[0,0,0,0,1],[0,1,1,1,1],[1,0,0,0,1],[0,1,1,1,1]]},{"id":98,"symbol":"b","content":[[1,0,0,0,0],[1,0,0,0,0],[1,0,1,1,0],[1,1,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,1,1,1,0]]},{"id":99,"symbol":"c","content":[[0,0,0,0,0],[0,0,0,0,0],[0,1,1,1,0],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,1],[0,1,1,1,0]]},{"id":100,"symbol":"d","content":[[0,0,0,0,1],[0,0,0,0,1],[0,1,1,0,1],[1,0,0,1,1],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,1]]},{"id":101,"symbol":"e","content":[[0,0,0,0,0],[0,0,0,0,0],[0,1,1,1,0],[1,0,0,0,1],[1,1,1,1,1],[1,0,0,0,0],[0,1,1,1,0]]},{"id":102,"symbol":"f","content":[[0,0,1,1,0],[0,1,0,0,1],[0,1,0,0,0],[1,1,1,0,0],[0,1,0,0,0],[0,1,0,0,0],[0,1,0,0,0]]},{"id":103,"symbol":"g","content":[[0,0,0,0,0],[0,0,0,0,0],[0,1,1,1,1],[1,0,0,0,1],[0,1,1,1,1],[0,0,0,0,1],[0,1,1,1,0]]},{"id":104,"symbol":"h","content":[[1,0,0,0,0],[1,0,0,0,0],[1,0,1,1,0],[1,1,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1]]},{"id":105,"symbol":"i","content":[[0,0,1,0,0],[0,0,0,0,0],[0,0,1,0,0],[0,1,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,1,1,1,0]]},{"id":106,"symbol":"j","content":[[0,0,0,1,0],[0,0,0,0,0],[0,0,1,1,0],[0,0,0,1,0],[0,0,0,1,0],[1,0,0,1,0],[0,1,1,0,0]]},{"id":107,"symbol":"k","content":[[1,0,0,0,0],[1,0,0,0,0],[1,0,0,1,0],[1,0,1,0,0],[1,1,0,0,0],[1,0,1,0,0],[1,0,0,1,0]]},{"id":108,"symbol":"l","content":[[0,1,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,1,1,1,0]]},{"id":109,"symbol":"m","content":[[0,0,0,0,0],[0,0,0,0,0],[1,1,0,1,0],[1,0,1,0,1],[1,0,1,0,1],[1,0,1,0,1],[1,0,1,0,1]]},{"id":110,"symbol":"n","content":[[0,0,0,0,0],[0,0,0,0,0],[1,0,1,1,0],[1,1,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1]]},{"id":111,"symbol":"o","content":[[0,0,0,0,0],[0,0,0,0,0],[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]]},{"id":112,"symbol":"p","content":[[0,0,0,0,0],[0,0,0,0,0],[1,1,1,1,0],[1,0,0,0,1],[1,1,1,1,0],[1,0,0,0,0],[1,0,0,0,0]]},{"id":113,"symbol":"q","content":[[0,0,0,0,0],[0,0,0,0,0],[0,1,1,1,1],[1,0,0,0,1],[0,1,1,1,1],[0,0,0,0,1],[0,0,0,0,1]]},{"id":114,"symbol":"r","content":[[0,0,0,0,0],[0,0,0,0,0],[1,0,1,1,0],[1,1,0,0,1],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0]]},{"id":115,"symbol":"s","content":[[0,0,0,0,0],[0,0,0,0,0],[0,1,1,1,0],[1,0,0,0,0],[0,1,1,1,0],[0,0,0,0,1],[1,1,1,1,0]]},{"id":116,"symbol":"t","content":[[0,1,0,0,0],[0,1,0,0,0],[1,1,1,0,0],[0,1,0,0,0],[0,1,0,0,0],[0,1,0,0,1],[0,0,1,1,0]]},{"id":117,"symbol":"u","content":[[0,0,0,0,0],[0,0,0,0,0],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,1,1],[0,1,1,0,1]]},{"id":118,"symbol":"v","content":[[0,0,0,0,0],[0,0,0,0,0],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[0,1,0,1,0],[0,0,1,0,0]]},{"id":119,"symbol":"w","content":[[0,0,0,0,0],[0,0,0,0,0],[1,0,0,0,1],[1,0,0,0,1],[1,0,1,0,1],[1,0,1,0,1],[0,1,0,1,0]]},{"id":120,"symbol":"x","content":[[0,0,0,0,0],[0,0,0,0,0],[1,0,0,0,1],[0,1,0,1,0],[0,0,1,0,0],[0,1,0,1,0],[1,0,0,0,1]]},{"id":121,"symbol":"y","content":[[0,0,0,0,0],[0,0,0,0,0],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,1],[0,0,0,0,1],[0,1,1,1,0]]},{"id":122,"symbol":"z","content":[[0,0,0,0,0],[0,0,0,0,0],[1,1,1,1,1],[0,0,0,1,0],[0,0,1,0,0],[0,1,0,0,0],[1,1,1,1,1]]},{"id":123,"symbol":"{","content":[[0,0,0,1,0],[0,0,1,0,0],[0,0,1,0,0],[0,1,0,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,0,1,0]]},{"id":124,"symbol":"|","content":[[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0]]},{"id":125,"symbol":"}","content":[[0,1,0,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,0,1,0],[0,0,1,0,0],[0,0,1,0,0],[0,1,0,0,0]]},{"id":126,"symbol":"~","content":[[0,0,0,0,0],[0,1,0,0,1],[1,0,1,1,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0]]}],"faceModules":{"0":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"101":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,1,0,0,0,0],[0,0,1,1,0,0,0,0],[0,0,1,1,0,0,0,0],[0,0,1,1,0,0,0,0],[0,0,0,0,0,0,0,0]],"102":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,0,0,0,0,0,0],[0,0,1,1,0,0,0,0],[0,0,1,1,0,0,0,0],[0,0,1,1,0,0,0,0],[0,0,1,1,0,0,0,0],[0,0,0,0,0,0,0,0]],"103":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,1,0,0,0,0],[0,0,1,0,1,0,0,0],[0,1,0,0,0,1,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"104":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,1,1,0,0,0],[0,0,1,0,0,1,0,0],[0,1,0,0,0,0,1,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"105":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,1,0,0,0,0],[0,0,1,0,1,0,0,0],[0,1,0,0,0,1,0,0],[1,0,0,0,0,0,1,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"106":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,0,0,0,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,1,0,0],[0,0,0,1,1,0,0,0],[0,1,1,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"107":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,0,0,0,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,1,0,0],[0,1,1,1,1,0,0,0],[0,0,0,0,0,0,0,0]],"108":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,1,1,1,1,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"109":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,1,1,1,1,0],[1,0,1,0,0,0,0,0],[0,1,0,0,0,0,0,0]],"110":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,0,0,0,0,0,0],[0,0,1,1,1,1,0,0],[0,0,0,0,0,0,0,0]],"111":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,0,0,0,1,0,0],[0,0,1,1,1,0,0,0],[0,0,0,0,0,0,0,0]],"112":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,0,0,0,0,1,0],[0,0,1,0,0,1,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"113":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,0,0,0,0,0],[0,0,0,1,1,1,1,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"114":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,1,0,0,0,0],[0,0,0,0,1,1,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"115":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,0,0,0,0,0],[0,0,0,1,0,0,0,0],[0,0,0,0,1,1,0,0],[0,0,0,0,0,0,0,0]],"116":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,1,0,0,0,0],[0,0,1,1,1,1,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,0,0,0]],"117":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,1,0,0,0],[0,0,0,1,0,0,0,0],[0,1,1,1,0,0,0,0],[0,0,1,1,0,0,0,0],[0,0,1,1,0,0,0,0],[0,0,0,0,0,0,0,0]],"118":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,0,0,0,0,0,0],[0,0,1,0,0,0,0,0],[0,0,1,1,1,0,0,0],[0,0,1,1,0,0,0,0],[0,0,1,1,0,0,0,0],[0,0,0,0,0,0,0,0]],"119":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,1,0,0,0,0],[0,1,1,0,1,0,0,0],[0,1,1,1,1,0,0,0],[0,0,1,1,0,0,0,0],[0,0,0,0,0,0,0,0]],"120":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,1,0,0,0,0],[0,1,1,0,1,0,0,0],[0,1,1,1,1,0,0,0],[1,0,1,1,0,0,0,0],[0,1,0,0,0,0,0,0]],"121":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,1,0,0,0,0],[0,1,1,1,0,0,0,0],[0,1,1,1,1,0,0,0],[0,0,1,1,0,0,0,0],[0,0,0,0,0,0,0,0]],"122":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,1,1,0,0,0],[0,1,0,0,0,1,0,0],[0,0,0,0,1,0,0,0],[0,0,0,1,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,1,0,0,0,0]],"123":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,0,0,0,1,0,0],[0,0,1,0,1,0,0,0],[0,0,0,1,0,0,0,0],[0,0,1,0,1,0,0,0],[0,1,0,0,0,1,0,0],[0,0,0,0,0,0,0,0]],"124":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,1,0,0,0,0],[0,0,1,1,1,0,0,0],[0,1,1,1,1,1,0,0],[0,0,1,1,1,0,0,0],[0,0,0,1,0,0,0,0],[0,0,0,0,0,0,0,0]],"125":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,1,1,0,0,0],[0,1,0,0,0,1,0,0],[0,1,0,0,0,1,0,0],[0,1,0,0,0,1,0,0],[0,0,1,1,1,0,0,0],[0,0,0,0,0,0,0,0]],"126":[[0,0,0,0,0,0,0,0],[0,0,0,1,0,0,0,0],[0,0,1,0,1,0,0,0],[0,1,0,0,0,1,0,0],[1,0,0,0,0,0,1,0],[0,1,0,0,0,1,0,0],[0,0,1,0,1,0,0,0],[0,0,0,1,0,0,0,0]],"127":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,0,1,1,0,0],[1,0,0,1,0,0,1,0],[1,0,0,0,0,0,1,0],[0,1,0,0,0,1,0,0],[0,0,1,0,1,0,0,0],[0,0,0,1,0,0,0,0]],"201":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,1,1,0,0],[0,0,0,0,1,1,0,0],[0,0,0,0,1,1,0,0],[0,0,0,0,1,1,0,0],[0,0,0,0,0,0,0,0]],"202":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,1,0],[0,0,0,0,1,1,0,0],[0,0,0,0,1,1,0,0],[0,0,0,0,1,1,0,0],[0,0,0,0,1,1,0,0],[0,0,0,0,0,0,0,0]],"203":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,1,0,0,0],[0,0,0,1,0,1,0,0],[0,0,1,0,0,0,1,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"204":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,1,1,0,0,0],[0,0,1,0,0,1,0,0],[0,1,0,0,0,0,1,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"205":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,1,0,0,0],[0,0,0,1,0,1,0,0],[0,0,1,0,0,0,1,0],[0,1,0,0,0,0,0,1],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"206":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,1,1,0],[0,0,0,1,1,0,0,0],[0,0,1,0,0,0,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,1,1,0],[0,0,0,0,0,0,0,0]],"207":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,1,1,0],[0,0,0,1,1,0,0,0],[0,0,1,0,0,0,0,0],[0,0,0,1,1,1,1,0],[0,0,0,0,0,0,0,0]],"208":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,1,1,1,1,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"209":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,1,1,1,1,0],[0,0,0,0,0,1,0,1],[0,0,0,0,0,0,1,0]],"210":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,1,0],[0,0,1,1,1,1,0,0],[0,0,0,0,0,0,0,0]],"211":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,0,0,0,1,0],[0,0,0,1,1,1,0,0],[0,0,0,0,0,0,0,0]],"212":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,0,0,0,0,1,0],[0,0,1,0,0,1,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"213":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,1,1,0],[0,1,1,1,1,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"214":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,1,1,1,0],[0,0,1,1,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"215":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,1,1,0],[0,0,0,0,1,0,0,0],[0,0,1,1,0,0,0,0],[0,0,0,0,0,0,0,0]],"216":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,1,1,0,0],[0,0,1,1,1,1,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,0,0,0]],"217":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,1,0,0,0,0],[0,0,0,0,1,0,0,0],[0,0,0,0,1,1,1,0],[0,0,0,0,1,1,0,0],[0,0,0,0,1,1,0,0],[0,0,0,0,0,0,0,0]],"218":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,1,0],[0,0,0,0,0,1,0,0],[0,0,0,1,1,1,0,0],[0,0,0,0,1,1,0,0],[0,0,0,0,1,1,0,0],[0,0,0,0,0,0,0,0]],"219":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,1,1,0,0],[0,0,0,1,0,1,1,0],[0,0,0,1,1,1,1,0],[0,0,0,0,1,1,0,0],[0,0,0,0,0,0,0,0]],"220":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,1,1,0,0],[0,0,0,1,0,1,1,0],[0,0,0,1,1,1,1,0],[0,0,0,0,1,1,0,1],[0,0,0,0,0,0,1,0]],"221":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,1,1,0,0],[0,0,0,0,1,1,1,0],[0,0,0,1,1,1,1,0],[0,0,0,0,1,1,0,0],[0,0,0,0,0,0,0,0]],"222":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,1,0,0,0],[0,0,0,0,1,0,0,0],[0,0,0,0,1,0,0,0],[0,0,0,0,1,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,1,0,0,0]],"223":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,0,0,0,1,0],[0,0,0,1,0,1,0,0],[0,0,0,0,1,0,0,0],[0,0,0,1,0,1,0,0],[0,0,1,0,0,0,1,0],[0,0,0,0,0,0,0,0]],"224":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,1,0,0,0],[0,0,0,1,1,1,0,0],[0,0,1,1,1,1,1,0],[0,0,0,1,1,1,0,0],[0,0,0,0,1,0,0,0],[0,0,0,0,0,0,0,0]],"225":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,1,1,1,0,0],[0,0,1,0,0,0,1,0],[0,0,1,0,0,0,1,0],[0,0,1,0,0,0,1,0],[0,0,0,1,1,1,0,0],[0,0,0,0,0,0,0,0]],"226":[[0,0,0,0,0,0,0,0],[0,0,0,0,1,0,0,0],[0,0,0,1,0,1,0,0],[0,0,1,0,0,0,1,0],[0,1,0,0,0,0,0,1],[0,0,1,0,0,0,1,0],[0,0,0,1,0,1,0,0],[0,0,0,0,1,0,0,0]],"227":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,1,0,1,1,0],[0,1,0,0,1,0,0,1],[0,1,0,0,0,0,0,1],[0,0,1,0,0,0,1,0],[0,0,0,1,0,1,0,0],[0,0,0,0,1,0,0,0]],"301":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,1,1,1,1,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"302":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[1,0,0,0,0,0,0,1],[0,1,1,1,1,1,1,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"303":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,1,1,1,1,0],[1,0,0,0,0,0,0,1],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"304":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[1,0,0,0,0,0,0,1],[0,1,0,0,0,0,1,0],[0,0,1,1,1,1,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"305":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[1,0,0,0,0,0,0,1],[0,1,0,0,0,0,1,0],[0,0,1,0,0,1,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"306":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,0,0,0,0,1,0],[0,0,1,0,0,1,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"307":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,1,1,0,0,0],[0,0,1,0,0,1,0,0],[0,1,0,0,0,0,1,0],[1,0,0,0,0,0,0,1],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"308":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,1,1,0,0,0],[0,0,1,0,0,1,0,0],[0,1,0,0,0,0,1,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"309":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,1,0],[1,0,0,0,0,1,0,1],[0,1,0,0,0,1,1,0],[0,0,1,1,1,1,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"310":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[1,1,1,1,1,1,1,1],[1,0,0,0,0,0,0,1],[0,1,0,0,0,0,1,0],[0,0,1,0,0,1,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,0,0,0]],"311":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[1,1,1,1,1,1,1,1],[1,0,0,0,0,0,0,1],[1,0,0,0,0,0,0,1],[0,1,0,0,0,0,1,0],[0,0,1,1,1,1,0,0],[0,0,0,0,0,0,0,0]],"312":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,1,1,1,0,0],[0,1,0,0,0,0,1,0],[0,1,0,0,0,0,1,0],[0,0,1,0,0,1,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,0,0,0]],"313":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,1,1,1,1,0],[0,1,0,0,0,0,1,0],[0,0,1,0,0,1,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"314":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,1,1,1,0,0],[0,1,0,0,0,0,1,0],[1,0,0,0,0,0,0,1],[1,0,0,0,0,0,0,1],[1,1,1,1,1,1,1,1],[0,0,0,0,0,0,0,0]],"315":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,1,1,1,0,0],[0,1,0,0,0,0,1,0],[0,1,0,0,0,0,1,0],[1,0,0,0,0,0,0,1],[0,1,1,1,1,1,1,0],[0,0,0,0,0,0,0,0]],"316":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,1,1,0,0,0],[0,0,1,0,0,1,0,0],[0,1,0,0,0,0,1,0],[0,1,0,0,0,0,1,0],[0,0,1,0,0,1,0,0],[0,0,0,1,1,0,0,0]],"317":[[0,0,0,0,0,0,0,0],[0,0,0,1,1,0,0,0],[0,0,1,0,0,1,0,0],[0,0,1,0,0,1,0,0],[0,0,1,0,0,1,0,0],[0,0,1,0,0,1,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,0,0,0]],"318":[[0,0,0,1,1,0,0,0],[0,0,1,0,0,1,0,0],[0,0,1,0,0,1,0,0],[0,0,1,0,0,1,0,0],[0,0,1,0,0,1,0,0],[0,0,1,0,0,1,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,0,0,0]],"319":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,1,1,0,0,0],[0,0,1,0,0,1,0,0],[0,0,1,0,0,1,0,0],[0,0,0,1,1,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"320":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[1,1,1,1,1,1,1,1],[1,0,0,0,0,0,0,1],[1,1,1,1,1,1,1,1],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"321":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[1,1,1,1,1,1,1,1],[1,0,0,0,0,0,0,1],[0,1,1,1,1,1,1,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"322":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,1,1,1,1,0],[1,0,0,0,0,0,0,1],[1,1,1,1,1,1,1,1],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"323":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,1,1,1,1,0],[0,1,0,0,0,0,1,0],[0,0,1,1,1,1,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"324":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,1,1,1,0,0],[0,1,0,0,0,0,1,0],[0,1,1,1,1,1,1,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"325":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,1,1,1,1,0],[0,1,0,0,0,0,1,0],[0,1,1,1,1,1,1,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"326":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[1,0,0,0,0,0,0,1],[0,1,0,0,0,0,1,0],[0,1,1,1,1,1,1,0],[0,1,0,0,0,0,1,0],[1,0,0,0,0,0,0,1],[0,0,0,0,0,0,0,0]],"327":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,0,0,1,1,0],[1,0,0,1,1,0,0,1],[1,0,0,0,0,0,0,1],[1,0,0,1,1,0,0,1],[0,1,1,0,0,1,1,0],[0,0,0,0,0,0,0,0]],"328":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,1,0,0,1,1,0],[1,0,0,1,1,0,0,1],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"329":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,1,0,0,1,0,0],[0,1,0,1,1,0,1,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"330":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,0,0,0,0,1,0],[0,1,0,1,1,0,1,0],[0,0,1,0,0,1,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"331":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,1,0,0,0,0,1,0],[0,1,0,1,1,0,1,0],[0,0,1,0,0,1,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"332":[[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,1,0],[0,1,0,1,0,0,1,0],[0,0,1,0,1,1,0,0],[0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0]],"400":[[0,0,0,0],[0,0,0,0],[0,0,0,0],[0,0,0,0]],"401":[[0,0,0,0],[0,1,1,0],[0,0,0,0],[0,0,0,0]],"402":[[0,0,0,0],[0,1,0,1],[0,0,0,0],[0,0,0,0]],"403":[[0,1,0,1],[1,0,1,0],[0,0,0,0],[0,0,0,0]],"404":[[1,0,1,0],[0,1,0,1],[0,0,0,0],[0,0,0,0]],"405":[[0,0,0,0],[0,1,1,1],[0,0,0,0],[0,1,1,1]]},"voiceDb":[{"id":0,"content":"璃奈板 笑眯眯"},{"id":1,"content":"璃奈板 害羞"},{"id":2,"content":"璃奈板 呒"},{"id":3,"content":"璃奈板 激动"},{"id":4,"content":"璃奈板 兴奋"},{"id":5,"content":"璃奈板 犀利"},{"id":6,"content":"璃奈板 熊熊燃烧"},{"id":7,"content":"璃奈板 ？"},{"id":8,"content":"璃奈板 啊哇哇"},{"id":9,"content":"璃奈板 头晕目眩"},{"id":10,"content":"璃奈板 呜"},{"id":11,"content":"璃奈板 沮丧"},{"id":12,"content":"璃奈板 泪眼汪汪"},{"id":13,"content":"璃奈板 感动"},{"id":14,"content":"璃奈板 啵哇旺"},{"id":15,"content":"璃奈板 闪闪发光"},{"id":16,"content":"璃奈板 高高兴兴"},{"id":17,"content":"璃奈板 点头"},{"id":18,"content":"璃奈板 V"},{"id":19,"content":"璃奈板 努力 冲"},{"id":20,"content":"璃奈板 加了个油"},{"id":21,"content":"璃奈板 干劲满满"},{"id":22,"content":"璃奈板 AAO"},{"id":23,"content":"璃奈板 竭尽全力嘞"},{"id":24,"content":"璃奈板 走吧"},{"id":25,"content":"璃奈板 加油"},{"id":26,"content":"璃奈板 加油啊"},{"id":27,"content":"璃奈板 鼓足气势"},{"id":28,"content":"璃奈板 大呼一口气"},{"id":29,"content":"璃奈板 好耶"},{"id":30,"content":"璃奈板 哇"},{"id":31,"content":"璃奈板 干的漂亮"},{"id":32,"content":"璃奈板 状态饱满"},{"id":33,"content":"璃奈板 超兴奋"},{"id":34,"content":"璃奈板 号角登登"},{"id":35,"content":"璃奈板 让我们上吧"},{"id":36,"content":"璃奈板 噜噜"},{"id":37,"content":"璃奈板 啦啦噜噜"},{"id":38,"content":"璃奈板 躁动不已"},{"id":39,"content":"璃奈板 兴奋不已"},{"id":40,"content":"璃奈板 激动兴奋"},{"id":41,"content":"璃奈板 激奋"},{"id":42,"content":"璃奈板 激动激动噜噜噜"},{"id":43,"content":"璃奈板 高高兴兴笑眯眯"},{"id":44,"content":"璃奈板 耶"},{"id":45,"content":"璃奈板 抿嘴一笑"},{"id":46,"content":"璃奈板 嘿嘿嘿"},{"id":47,"content":"璃奈板 窃笑"},{"id":48,"content":"璃奈板 嘲笑"},{"id":49,"content":"璃奈板 生气气"},{"id":50,"content":"璃奈板 气鼓鼓"},{"id":51,"content":"璃奈板 思索思索"},{"id":52,"content":"璃奈板 无奈"},{"id":53,"content":"璃奈板 无语"},{"id":54,"content":"璃奈板 无话可说"},{"id":55,"content":"璃奈板 哔哔哔"},{"id":56,"content":"璃奈板 哔空"},{"id":57,"content":"璃奈板 叮咚"},{"id":58,"content":"璃奈板 错错"},{"id":59,"content":"璃奈板 吓一跳"},{"id":60,"content":"璃奈板 完美"},{"id":61,"content":"璃奈板 得意"},{"id":62,"content":"璃奈板 咻咻"},{"id":63,"content":"璃奈板 闪亮亮"},{"id":64,"content":"璃奈板 闪亮"},{"id":65,"content":"璃奈板 亮"},{"id":66,"content":"璃奈板 大开灯"},{"id":67,"content":"璃奈板 嗨的很"},{"id":68,"content":"璃奈板 受惊"},{"id":69,"content":"璃奈板 颓废"},{"id":70,"content":"璃奈板 眼冒金星"},{"id":71,"content":"璃奈板 不可置信"},{"id":72,"content":"璃奈板 我倒"},{"id":73,"content":"璃奈板 我躺"},{"id":74,"content":"璃奈板 郁闷"},{"id":75,"content":"璃奈板 抽泣"},{"id":76,"content":"璃奈板 无精打采"},{"id":77,"content":"璃奈板 提不起劲"},{"id":78,"content":"璃奈板 喜出望外"},{"id":79,"content":"璃奈板 断然"},{"id":80,"content":"璃奈板 哼唧唧"},{"id":81,"content":"璃奈板 好气啊"},{"id":82,"content":"璃奈板 生气"},{"id":83,"content":"璃奈板 怒火中烧"},{"id":84,"content":"璃奈板 晃眼"},{"id":85,"content":"璃奈板 咽口水"},{"id":86,"content":"璃奈板 担心"},{"id":87,"content":"璃奈板 泪眼婆娑"},{"id":88,"content":"璃奈板 扭扭捏捏"},{"id":89,"content":"璃奈板 乖巧"},{"id":90,"content":"璃奈板 坐立不安"},{"id":91,"content":"璃奈板 起鸡皮疙瘩"},{"id":92,"content":"璃奈板 紧张兮兮"},{"id":93,"content":"璃奈板 哆哆嗦嗦"},{"id":94,"content":"璃奈板 瑟瑟发抖"},{"id":95,"content":"璃奈板 风尘仆仆"},{"id":96,"content":"璃奈板 筋疲力尽"},{"id":97,"content":"璃奈板 瘫倒无力"},{"id":98,"content":"璃奈板 晕倒"},{"id":99,"content":"璃奈板 吼"},{"id":100,"content":"璃奈板 落泪"},{"id":101,"content":"璃奈板 泪汪汪"},{"id":102,"content":"璃奈板 暖洋洋"},{"id":103,"content":"璃奈板 悠哉游哉"},{"id":104,"content":"璃奈板 心荡神驰"},{"id":105,"content":"璃奈板 发呆"},{"id":106,"content":"璃奈板 治愈"},{"id":107,"content":"璃奈板 暖心"},{"id":108,"content":"璃奈板 轻飘飘"},{"id":109,"content":"璃奈板 慢悠悠"},{"id":110,"content":"璃奈板 耐人寻味"},{"id":111,"content":"璃奈板 抱紧"},{"id":112,"content":"璃奈板 啾啾"},{"id":113,"content":"璃奈板 比心"},{"id":114,"content":"璃奈板 啾噜噜"},{"id":115,"content":"璃奈板 亲"},{"id":116,"content":"璃奈板 笑眯眯 笑眯眯"},{"id":117,"content":"璃奈板 笑容满面"},{"id":118,"content":"璃奈板 舔舌头"},{"id":119,"content":"璃奈板 咀嚼"},{"id":120,"content":"璃奈板 吹吹冷"},{"id":121,"content":"璃奈板 软乎乎"},{"id":122,"content":"璃奈板 太软啦"},{"id":123,"content":"璃奈板 吃饱饱"},{"id":124,"content":"璃奈板 困困"},{"id":125,"content":"璃奈板 傻眼"},{"id":126,"content":"璃奈板 闪亮登场"},{"id":127,"content":"璃奈板 坚定"},{"id":128,"content":"璃奈板 水灵灵"},{"id":129,"content":"璃奈板 哈喽"},{"id":130,"content":"璃奈板 早上中午晚上好"},{"id":131,"content":"璃奈板 欢迎回来"},{"id":132,"content":"璃奈板 不能摘下来"},{"id":133,"content":"璃奈板 嗨起来"},{"id":134,"content":"璃奈板 兔子跳"},{"id":135,"content":"璃奈板 喵喵"},{"id":136,"content":"璃奈板 喵"},{"id":137,"content":"璃奈板 收到"},{"id":138,"content":"璃奈板 开心"},{"id":139,"content":"璃奈板 热血沸腾"},{"id":140,"content":"璃奈板 谢谢"},{"id":141,"content":"璃奈板 接下来也请多关照了"},{"id":142,"content":"璃奈板 再见"}],"voiceTimelines":{"voice_0":[{"frame":3,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":12,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":17,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":22,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":24,"face":{"leye":106,"reye":206,"mouth":310,"cheek":402}}],"voice_1":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":17,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":19,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":22,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}}],"voice_2":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":310,"cheek":400}},{"frame":3,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":116,"reye":216,"mouth":302,"cheek":402}}],"voice_3":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}},{"frame":2,"face":{"leye":101,"reye":201,"mouth":301,"cheek":402}},{"frame":5,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":319,"cheek":402}},{"frame":10,"face":{"leye":101,"reye":201,"mouth":301,"cheek":402}},{"frame":14,"face":{"leye":110,"reye":210,"mouth":312,"cheek":403}},{"frame":17,"face":{"leye":110,"reye":210,"mouth":302,"cheek":403}},{"frame":19,"face":{"leye":110,"reye":210,"mouth":312,"cheek":403}},{"frame":21,"face":{"leye":110,"reye":210,"mouth":302,"cheek":403}}],"voice_4":[{"frame":0,"face":{"leye":106,"reye":206,"mouth":310,"cheek":400}},{"frame":1,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":8,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":13,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":14,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":17,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":19,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}}],"voice_5":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":14,"face":{"leye":116,"reye":216,"mouth":302,"cheek":402}}],"voice_6":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":7,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":301,"cheek":400}},{"frame":15,"face":{"leye":116,"reye":216,"mouth":321,"cheek":402}},{"frame":17,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":20,"face":{"leye":116,"reye":216,"mouth":321,"cheek":402}},{"frame":22,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":32,"face":{"leye":116,"reye":216,"mouth":302,"cheek":402}}],"voice_7":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":3,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":7,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":16,"face":{"leye":122,"reye":222,"mouth":327,"cheek":400}}],"voice_8":[{"frame":0,"face":{"leye":106,"reye":206,"mouth":322,"cheek":402}},{"frame":2,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":9,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":11,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":17,"face":{"leye":106,"reye":206,"mouth":315,"cheek":400}},{"frame":19,"face":{"leye":106,"reye":206,"mouth":303,"cheek":400}},{"frame":20,"face":{"leye":106,"reye":206,"mouth":315,"cheek":400}},{"frame":21,"face":{"leye":106,"reye":206,"mouth":0,"cheek":400}},{"frame":22,"face":{"leye":106,"reye":206,"mouth":315,"cheek":400}}],"voice_9":[{"frame":0,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":4,"face":{"leye":117,"reye":217,"mouth":303,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":12,"face":{"leye":110,"reye":210,"mouth":328,"cheek":400}},{"frame":18,"face":{"leye":122,"reye":222,"mouth":304,"cheek":400}},{"frame":21,"face":{"leye":122,"reye":222,"mouth":311,"cheek":400}},{"frame":24,"face":{"leye":122,"reye":222,"mouth":304,"cheek":400}},{"frame":26,"face":{"leye":122,"reye":222,"mouth":311,"cheek":400}}],"voice_10":[{"frame":0,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":3,"face":{"leye":117,"reye":217,"mouth":303,"cheek":400}},{"frame":7,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":20,"face":{"leye":119,"reye":220,"mouth":303,"cheek":400}}],"voice_11":[{"frame":0,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":3,"face":{"leye":117,"reye":217,"mouth":303,"cheek":400}},{"frame":7,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":10,"face":{"leye":110,"reye":210,"mouth":322,"cheek":400}},{"frame":13,"face":{"leye":110,"reye":210,"mouth":303,"cheek":400}},{"frame":19,"face":{"leye":119,"reye":220,"mouth":322,"cheek":400}},{"frame":22,"face":{"leye":119,"reye":220,"mouth":301,"cheek":400}},{"frame":23,"face":{"leye":119,"reye":220,"mouth":314,"cheek":400}}],"voice_12":[{"frame":0,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":2,"face":{"leye":117,"reye":217,"mouth":328,"cheek":400}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":328,"cheek":400}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":322,"cheek":400}},{"frame":9,"face":{"leye":106,"reye":206,"mouth":322,"cheek":400}},{"frame":11,"face":{"leye":106,"reye":206,"mouth":328,"cheek":400}},{"frame":16,"face":{"leye":119,"reye":220,"mouth":322,"cheek":400}},{"frame":19,"face":{"leye":119,"reye":220,"mouth":303,"cheek":400}},{"frame":21,"face":{"leye":119,"reye":220,"mouth":322,"cheek":400}},{"frame":24,"face":{"leye":119,"reye":220,"mouth":303,"cheek":400}}],"voice_13":[{"frame":0,"face":{"leye":106,"reye":206,"mouth":322,"cheek":402}},{"frame":1,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":9,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":11,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":17,"face":{"leye":119,"reye":220,"mouth":321,"cheek":402}},{"frame":29,"face":{"leye":119,"reye":220,"mouth":302,"cheek":402}}],"voice_14":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":312,"cheek":402}},{"frame":2,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":8,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":10,"face":{"leye":101,"reye":201,"mouth":302,"cheek":402}},{"frame":15,"face":{"leye":110,"reye":210,"mouth":312,"cheek":402}},{"frame":16,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":23,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}}],"voice_15":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":3,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":101,"reye":206,"mouth":321,"cheek":400}},{"frame":18,"face":{"leye":0,"reye":0,"mouth":0,"cheek":400}},{"frame":19,"face":{"leye":106,"reye":201,"mouth":311,"cheek":400}}],"voice_16":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":1,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":2,"face":{"leye":111,"reye":211,"mouth":304,"cheek":400}},{"frame":4,"face":{"leye":111,"reye":211,"mouth":311,"cheek":400}},{"frame":7,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":14,"face":{"leye":105,"reye":205,"mouth":319,"cheek":403}},{"frame":16,"face":{"leye":105,"reye":205,"mouth":321,"cheek":403}},{"frame":18,"face":{"leye":105,"reye":205,"mouth":319,"cheek":403}},{"frame":20,"face":{"leye":105,"reye":205,"mouth":321,"cheek":403}}],"voice_17":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":312,"cheek":402}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":9,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":302,"cheek":402}},{"frame":16,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":18,"face":{"leye":110,"reye":210,"mouth":301,"cheek":400}},{"frame":20,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":202,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}}],"voice_18":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":14,"face":{"leye":101,"reye":206,"mouth":305,"cheek":402}}],"voice_19":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":121,"reye":221,"mouth":311,"cheek":402}},{"frame":12,"face":{"leye":121,"reye":221,"mouth":304,"cheek":402}},{"frame":15,"face":{"leye":121,"reye":221,"mouth":311,"cheek":402}},{"frame":17,"face":{"leye":121,"reye":221,"mouth":304,"cheek":402}},{"frame":19,"face":{"leye":121,"reye":221,"mouth":312,"cheek":402}},{"frame":27,"face":{"leye":121,"reye":221,"mouth":304,"cheek":402}},{"frame":29,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":40,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}}],"voice_20":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":1,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":2,"face":{"leye":111,"reye":211,"mouth":304,"cheek":400}},{"frame":4,"face":{"leye":111,"reye":211,"mouth":311,"cheek":400}},{"frame":7,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":13,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":15,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":18,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":24,"face":{"leye":106,"reye":206,"mouth":0,"cheek":400}},{"frame":25,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}}],"voice_21":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":7,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":18,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":20,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":23,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":24,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":27,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}}],"voice_22":[{"frame":0,"face":{"leye":121,"reye":221,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":121,"reye":221,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":121,"reye":221,"mouth":311,"cheek":400}},{"frame":14,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":19,"face":{"leye":102,"reye":202,"mouth":323,"cheek":400}},{"frame":22,"face":{"leye":102,"reye":202,"mouth":302,"cheek":400}},{"frame":26,"face":{"leye":102,"reye":202,"mouth":323,"cheek":400}},{"frame":30,"face":{"leye":102,"reye":202,"mouth":302,"cheek":400}},{"frame":34,"face":{"leye":107,"reye":207,"mouth":311,"cheek":403}}],"voice_23":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":14,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":17,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":19,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":26,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}}],"voice_24":[{"frame":1,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":111,"reye":211,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":111,"reye":211,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":13,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":17,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":19,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}},{"frame":22,"face":{"leye":102,"reye":206,"mouth":311,"cheek":402}},{"frame":28,"face":{"leye":102,"reye":206,"mouth":304,"cheek":402}}],"voice_25":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":14,"face":{"leye":121,"reye":221,"mouth":311,"cheek":402}},{"frame":17,"face":{"leye":121,"reye":221,"mouth":304,"cheek":402}}],"voice_26":[{"frame":0,"face":{"leye":121,"reye":221,"mouth":304,"cheek":402}},{"frame":1,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":5,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":14,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":18,"face":{"leye":121,"reye":221,"mouth":311,"cheek":400}},{"frame":20,"face":{"leye":121,"reye":221,"mouth":304,"cheek":400}}],"voice_27":[{"frame":0,"face":{"leye":121,"reye":221,"mouth":304,"cheek":400}},{"frame":1,"face":{"leye":121,"reye":221,"mouth":311,"cheek":400}},{"frame":5,"face":{"leye":121,"reye":221,"mouth":304,"cheek":400}},{"frame":9,"face":{"leye":121,"reye":221,"mouth":311,"cheek":400}},{"frame":15,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":20,"face":{"leye":121,"reye":221,"mouth":311,"cheek":402}},{"frame":23,"face":{"leye":121,"reye":221,"mouth":304,"cheek":402}},{"frame":28,"face":{"leye":107,"reye":207,"mouth":328,"cheek":402}}],"voice_28":[{"frame":0,"face":{"leye":107,"reye":207,"mouth":328,"cheek":402}},{"frame":1,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":5,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":13,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":17,"face":{"leye":121,"reye":221,"mouth":326,"cheek":402}},{"frame":20,"face":{"leye":121,"reye":221,"mouth":304,"cheek":402}}],"voice_29":[{"frame":0,"face":{"leye":121,"reye":221,"mouth":304,"cheek":402}},{"frame":1,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":5,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":121,"reye":221,"mouth":311,"cheek":402}},{"frame":15,"face":{"leye":121,"reye":221,"mouth":304,"cheek":402}},{"frame":18,"face":{"leye":110,"reye":210,"mouth":310,"cheek":400}},{"frame":20,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}},{"frame":23,"face":{"leye":101,"reye":206,"mouth":311,"cheek":402}}],"voice_30":[{"frame":0,"face":{"leye":101,"reye":206,"mouth":311,"cheek":402}},{"frame":1,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":5,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":12,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":18,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":25,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}}],"voice_31":[{"frame":1,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":16,"face":{"leye":102,"reye":206,"mouth":309,"cheek":400}}],"voice_32":[{"frame":0,"face":{"leye":102,"reye":206,"mouth":309,"cheek":400}},{"frame":1,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":16,"face":{"leye":106,"reye":201,"mouth":311,"cheek":402}},{"frame":18,"face":{"leye":106,"reye":201,"mouth":304,"cheek":402}},{"frame":21,"face":{"leye":106,"reye":201,"mouth":311,"cheek":402}}],"voice_33":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":5,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":121,"reye":221,"mouth":311,"cheek":402}},{"frame":14,"face":{"leye":121,"reye":221,"mouth":304,"cheek":402}},{"frame":18,"face":{"leye":121,"reye":221,"mouth":311,"cheek":402}},{"frame":20,"face":{"leye":121,"reye":221,"mouth":304,"cheek":402}},{"frame":23,"face":{"leye":121,"reye":221,"mouth":310,"cheek":402}}],"voice_34":[{"frame":0,"face":{"leye":121,"reye":221,"mouth":310,"cheek":402}},{"frame":1,"face":{"leye":121,"reye":221,"mouth":311,"cheek":400}},{"frame":6,"face":{"leye":121,"reye":221,"mouth":304,"cheek":400}},{"frame":10,"face":{"leye":121,"reye":221,"mouth":311,"cheek":400}},{"frame":16,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":20,"face":{"leye":106,"reye":206,"mouth":310,"cheek":402}},{"frame":23,"face":{"leye":106,"reye":206,"mouth":306,"cheek":402}},{"frame":25,"face":{"leye":106,"reye":206,"mouth":310,"cheek":402}},{"frame":34,"face":{"leye":106,"reye":206,"mouth":305,"cheek":402}}],"voice_35":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":111,"reye":211,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":111,"reye":211,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":12,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":16,"face":{"leye":107,"reye":207,"mouth":321,"cheek":402}},{"frame":22,"face":{"leye":102,"reye":206,"mouth":311,"cheek":402}}],"voice_36":[{"frame":0,"face":{"leye":102,"reye":206,"mouth":311,"cheek":402}},{"frame":1,"face":{"leye":110,"reye":210,"mouth":312,"cheek":402}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":13,"face":{"leye":101,"reye":201,"mouth":302,"cheek":402}},{"frame":18,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":20,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}},{"frame":23,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":25,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}}],"voice_37":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}},{"frame":1,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":5,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":12,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":13,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":17,"face":{"leye":107,"reye":207,"mouth":311,"cheek":400}},{"frame":19,"face":{"leye":107,"reye":207,"mouth":302,"cheek":400}},{"frame":22,"face":{"leye":107,"reye":207,"mouth":311,"cheek":400}},{"frame":24,"face":{"leye":107,"reye":207,"mouth":302,"cheek":400}},{"frame":27,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":29,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}},{"frame":32,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":34,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}}],"voice_38":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}},{"frame":2,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":5,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":14,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":18,"face":{"leye":107,"reye":207,"mouth":319,"cheek":400}},{"frame":19,"face":{"leye":107,"reye":207,"mouth":306,"cheek":400}},{"frame":22,"face":{"leye":107,"reye":207,"mouth":319,"cheek":400}},{"frame":24,"face":{"leye":107,"reye":207,"mouth":306,"cheek":400}}],"voice_39":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":13,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":17,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":19,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":21,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":24,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":28,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":30,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":32,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":35,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}}],"voice_40":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":319,"cheek":402}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":10,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":14,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":21,"face":{"leye":101,"reye":201,"mouth":302,"cheek":402}},{"frame":27,"face":{"leye":110,"reye":210,"mouth":319,"cheek":403}},{"frame":33,"face":{"leye":110,"reye":210,"mouth":302,"cheek":403}},{"frame":35,"face":{"leye":110,"reye":210,"mouth":319,"cheek":403}},{"frame":37,"face":{"leye":110,"reye":210,"mouth":302,"cheek":403}},{"frame":39,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":41,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":43,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":43,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}}],"voice_41":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":301,"cheek":400}},{"frame":16,"face":{"leye":110,"reye":210,"mouth":312,"cheek":403}},{"frame":18,"face":{"leye":110,"reye":210,"mouth":302,"cheek":403}},{"frame":20,"face":{"leye":110,"reye":210,"mouth":311,"cheek":403}},{"frame":22,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":23,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}}],"voice_42":[{"frame":0,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":2,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":9,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":13,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":21,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":25,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":29,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":33,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":36,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":38,"face":{"leye":106,"reye":206,"mouth":330,"cheek":402}}],"voice_43":[{"frame":0,"face":{"leye":106,"reye":206,"mouth":331,"cheek":402}},{"frame":1,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":5,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":13,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":17,"face":{"leye":106,"reye":206,"mouth":305,"cheek":403}},{"frame":20,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":21,"face":{"leye":106,"reye":206,"mouth":305,"cheek":403}},{"frame":24,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":25,"face":{"leye":106,"reye":206,"mouth":304,"cheek":403}},{"frame":29,"face":{"leye":110,"reye":210,"mouth":304,"cheek":403}},{"frame":30,"face":{"leye":110,"reye":210,"mouth":310,"cheek":403}},{"frame":34,"face":{"leye":110,"reye":210,"mouth":304,"cheek":403}},{"frame":35,"face":{"leye":103,"reye":203,"mouth":304,"cheek":403}},{"frame":36,"face":{"leye":103,"reye":203,"mouth":310,"cheek":403}}],"voice_44":[{"frame":0,"face":{"leye":103,"reye":203,"mouth":310,"cheek":403}},{"frame":1,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":5,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":12,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":13,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":17,"face":{"leye":106,"reye":201,"mouth":310,"cheek":402}}],"voice_45":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":3,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":7,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":17,"face":{"leye":103,"reye":203,"mouth":302,"cheek":400}}],"voice_46":[{"frame":0,"face":{"leye":108,"reye":208,"mouth":323,"cheek":400}},{"frame":5,"face":{"leye":108,"reye":208,"mouth":303,"cheek":400}},{"frame":9,"face":{"leye":108,"reye":208,"mouth":323,"cheek":400}},{"frame":14,"face":{"leye":108,"reye":208,"mouth":303,"cheek":400}},{"frame":22,"face":{"leye":114,"reye":214,"mouth":302,"cheek":402}}],"voice_47":[{"frame":0,"face":{"leye":114,"reye":214,"mouth":302,"cheek":402}},{"frame":1,"face":{"leye":110,"reye":210,"mouth":312,"cheek":402}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":13,"face":{"leye":101,"reye":201,"mouth":302,"cheek":402}},{"frame":18,"face":{"leye":107,"reye":207,"mouth":306,"cheek":402}}],"voice_48":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":3,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":7,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":17,"face":{"leye":107,"reye":207,"mouth":306,"cheek":400}}],"voice_49":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":4,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":8,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":12,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":16,"face":{"leye":110,"reye":210,"mouth":308,"cheek":400}}],"voice_50":[{"frame":0,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":4,"face":{"leye":117,"reye":217,"mouth":303,"cheek":400}},{"frame":9,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":12,"face":{"leye":110,"reye":210,"mouth":322,"cheek":400}},{"frame":15,"face":{"leye":110,"reye":210,"mouth":303,"cheek":400}},{"frame":20,"face":{"leye":116,"reye":216,"mouth":326,"cheek":402}}],"voice_51":[{"frame":0,"face":{"leye":116,"reye":216,"mouth":326,"cheek":402}},{"frame":1,"face":{"leye":101,"reye":201,"mouth":316,"cheek":402}},{"frame":6,"face":{"leye":101,"reye":201,"mouth":302,"cheek":402}},{"frame":10,"face":{"leye":101,"reye":201,"mouth":316,"cheek":402}},{"frame":15,"face":{"leye":101,"reye":201,"mouth":322,"cheek":402}},{"frame":20,"face":{"leye":110,"reye":210,"mouth":315,"cheek":402}},{"frame":23,"face":{"leye":110,"reye":210,"mouth":328,"cheek":402}},{"frame":26,"face":{"leye":110,"reye":210,"mouth":315,"cheek":402}},{"frame":29,"face":{"leye":110,"reye":210,"mouth":328,"cheek":402}}],"voice_52":[{"frame":0,"face":{"leye":108,"reye":208,"mouth":321,"cheek":400}},{"frame":4,"face":{"leye":108,"reye":208,"mouth":303,"cheek":400}},{"frame":8,"face":{"leye":108,"reye":208,"mouth":321,"cheek":400}},{"frame":13,"face":{"leye":108,"reye":208,"mouth":303,"cheek":400}},{"frame":21,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}}],"voice_53":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":3,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":7,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":17,"face":{"leye":108,"reye":208,"mouth":301,"cheek":400}}],"voice_54":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":4,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":8,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":12,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":18,"face":{"leye":108,"reye":208,"mouth":301,"cheek":400}}],"voice_55":[{"frame":0,"face":{"leye":108,"reye":208,"mouth":301,"cheek":400}},{"frame":1,"face":{"leye":116,"reye":216,"mouth":322,"cheek":402}},{"frame":5,"face":{"leye":116,"reye":216,"mouth":303,"cheek":402}},{"frame":10,"face":{"leye":116,"reye":216,"mouth":316,"cheek":402}},{"frame":13,"face":{"leye":116,"reye":216,"mouth":301,"cheek":402}},{"frame":20,"face":{"leye":116,"reye":216,"mouth":321,"cheek":402}},{"frame":22,"face":{"leye":116,"reye":216,"mouth":0,"cheek":402}},{"frame":24,"face":{"leye":116,"reye":216,"mouth":302,"cheek":402}}],"voice_56":[{"frame":1,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":126,"reye":226,"mouth":310,"cheek":400}},{"frame":23,"face":{"leye":126,"reye":226,"mouth":305,"cheek":400}}],"voice_57":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":111,"reye":211,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":111,"reye":211,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":12,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":16,"face":{"leye":126,"reye":226,"mouth":310,"cheek":400}}],"voice_58":[{"frame":0,"face":{"leye":116,"reye":216,"mouth":315,"cheek":400}},{"frame":3,"face":{"leye":116,"reye":216,"mouth":307,"cheek":400}},{"frame":7,"face":{"leye":116,"reye":216,"mouth":314,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":314,"cheek":400}},{"frame":10,"face":{"leye":110,"reye":210,"mouth":303,"cheek":400}},{"frame":16,"face":{"leye":123,"reye":223,"mouth":303,"cheek":400}}],"voice_59":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":3,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":126,"reye":226,"mouth":315,"cheek":400}},{"frame":21,"face":{"leye":126,"reye":226,"mouth":301,"cheek":400}}],"voice_60":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":13,"face":{"leye":116,"reye":216,"mouth":304,"cheek":402}},{"frame":17,"face":{"leye":101,"reye":206,"mouth":310,"cheek":400}},{"frame":19,"face":{"leye":101,"reye":206,"mouth":302,"cheek":400}},{"frame":21,"face":{"leye":101,"reye":206,"mouth":310,"cheek":400}}],"voice_61":[{"frame":0,"face":{"leye":116,"reye":216,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":116,"reye":216,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":116,"reye":216,"mouth":311,"cheek":400}},{"frame":14,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":19,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":21,"face":{"leye":110,"reye":210,"mouth":0,"cheek":400}},{"frame":23,"face":{"leye":110,"reye":210,"mouth":310,"cheek":400}},{"frame":27,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}}],"voice_62":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":12,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":16,"face":{"leye":106,"reye":206,"mouth":310,"cheek":400}},{"frame":20,"face":{"leye":106,"reye":206,"mouth":305,"cheek":400}},{"frame":22,"face":{"leye":106,"reye":206,"mouth":310,"cheek":400}},{"frame":26,"face":{"leye":106,"reye":206,"mouth":305,"cheek":400}}],"voice_63":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":12,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":16,"face":{"leye":106,"reye":206,"mouth":321,"cheek":402}},{"frame":17,"face":{"leye":106,"reye":206,"mouth":310,"cheek":402}},{"frame":19,"face":{"leye":106,"reye":206,"mouth":321,"cheek":402}},{"frame":20,"face":{"leye":106,"reye":206,"mouth":310,"cheek":402}}],"voice_64":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":13,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":17,"face":{"leye":106,"reye":206,"mouth":310,"cheek":400}},{"frame":19,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":23,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}}],"voice_65":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":12,"face":{"leye":102,"reye":202,"mouth":301,"cheek":400}},{"frame":17,"face":{"leye":124,"reye":224,"mouth":310,"cheek":400}},{"frame":23,"face":{"leye":124,"reye":224,"mouth":305,"cheek":400}}],"voice_66":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":17,"face":{"leye":124,"reye":224,"mouth":305,"cheek":400}}],"voice_67":[{"frame":0,"face":{"leye":116,"reye":216,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":116,"reye":216,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":116,"reye":216,"mouth":311,"cheek":400}},{"frame":14,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":18,"face":{"leye":110,"reye":210,"mouth":314,"cheek":400}},{"frame":19,"face":{"leye":107,"reye":207,"mouth":314,"cheek":400}},{"frame":21,"face":{"leye":107,"reye":207,"mouth":302,"cheek":400}},{"frame":24,"face":{"leye":107,"reye":207,"mouth":314,"cheek":400}}],"voice_68":[{"frame":0,"face":{"leye":108,"reye":208,"mouth":323,"cheek":400}},{"frame":4,"face":{"leye":108,"reye":208,"mouth":303,"cheek":400}},{"frame":8,"face":{"leye":108,"reye":208,"mouth":323,"cheek":400}},{"frame":13,"face":{"leye":108,"reye":208,"mouth":303,"cheek":400}},{"frame":21,"face":{"leye":108,"reye":209,"mouth":314,"cheek":400}}],"voice_69":[{"frame":0,"face":{"leye":108,"reye":208,"mouth":324,"cheek":400}},{"frame":3,"face":{"leye":108,"reye":208,"mouth":301,"cheek":400}},{"frame":6,"face":{"leye":108,"reye":208,"mouth":324,"cheek":400}},{"frame":7,"face":{"leye":108,"reye":208,"mouth":322,"cheek":400}},{"frame":13,"face":{"leye":108,"reye":208,"mouth":301,"cheek":400}},{"frame":19,"face":{"leye":106,"reye":206,"mouth":314,"cheek":400}},{"frame":24,"face":{"leye":106,"reye":206,"mouth":324,"cheek":400}}],"voice_70":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":4,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":8,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":12,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":17,"face":{"leye":122,"reye":222,"mouth":322,"cheek":400}},{"frame":20,"face":{"leye":122,"reye":222,"mouth":328,"cheek":400}},{"frame":22,"face":{"leye":122,"reye":222,"mouth":322,"cheek":400}},{"frame":24,"face":{"leye":122,"reye":222,"mouth":328,"cheek":400}}],"voice_71":[{"frame":0,"face":{"leye":108,"reye":208,"mouth":321,"cheek":400}},{"frame":4,"face":{"leye":108,"reye":208,"mouth":303,"cheek":400}},{"frame":8,"face":{"leye":108,"reye":208,"mouth":321,"cheek":400}},{"frame":13,"face":{"leye":108,"reye":208,"mouth":303,"cheek":400}},{"frame":21,"face":{"leye":119,"reye":219,"mouth":314,"cheek":400}},{"frame":23,"face":{"leye":119,"reye":219,"mouth":321,"cheek":400}},{"frame":31,"face":{"leye":119,"reye":219,"mouth":303,"cheek":400}}],"voice_72":[{"frame":0,"face":{"leye":108,"reye":208,"mouth":322,"cheek":400}},{"frame":4,"face":{"leye":108,"reye":208,"mouth":301,"cheek":400}},{"frame":7,"face":{"leye":108,"reye":208,"mouth":322,"cheek":400}},{"frame":14,"face":{"leye":108,"reye":208,"mouth":301,"cheek":400}},{"frame":19,"face":{"leye":108,"reye":209,"mouth":315,"cheek":400}},{"frame":21,"face":{"leye":108,"reye":209,"mouth":322,"cheek":400}}],"voice_73":[{"frame":0,"face":{"leye":108,"reye":208,"mouth":315,"cheek":400}},{"frame":6,"face":{"leye":108,"reye":208,"mouth":326,"cheek":400}},{"frame":20,"face":{"leye":110,"reye":210,"mouth":315,"cheek":400}},{"frame":25,"face":{"leye":110,"reye":210,"mouth":301,"cheek":400}}],"voice_74":[{"frame":0,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":4,"face":{"leye":117,"reye":217,"mouth":303,"cheek":400}},{"frame":9,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":12,"face":{"leye":110,"reye":210,"mouth":322,"cheek":400}},{"frame":14,"face":{"leye":110,"reye":210,"mouth":303,"cheek":400}},{"frame":20,"face":{"leye":108,"reye":208,"mouth":315,"cheek":400}},{"frame":29,"face":{"leye":108,"reye":208,"mouth":307,"cheek":400}}],"voice_75":[{"frame":0,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":3,"face":{"leye":117,"reye":217,"mouth":303,"cheek":400}},{"frame":8,"face":{"leye":106,"reye":206,"mouth":314,"cheek":400}},{"frame":14,"face":{"leye":106,"reye":206,"mouth":303,"cheek":400}},{"frame":19,"face":{"leye":119,"reye":220,"mouth":322,"cheek":400}}],"voice_76":[{"frame":0,"face":{"leye":106,"reye":206,"mouth":315,"cheek":400}},{"frame":5,"face":{"leye":106,"reye":206,"mouth":322,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":322,"cheek":400}},{"frame":9,"face":{"leye":110,"reye":210,"mouth":314,"cheek":400}},{"frame":11,"face":{"leye":108,"reye":208,"mouth":314,"cheek":400}},{"frame":14,"face":{"leye":108,"reye":208,"mouth":322,"cheek":400}},{"frame":20,"face":{"leye":110,"reye":210,"mouth":315,"cheek":400}},{"frame":23,"face":{"leye":110,"reye":210,"mouth":322,"cheek":400}},{"frame":26,"face":{"leye":110,"reye":210,"mouth":301,"cheek":400}}],"voice_77":[{"frame":0,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":4,"face":{"leye":117,"reye":217,"mouth":303,"cheek":400}},{"frame":8,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":21,"face":{"leye":119,"reye":220,"mouth":319,"cheek":400}},{"frame":23,"face":{"leye":119,"reye":220,"mouth":322,"cheek":400}},{"frame":29,"face":{"leye":119,"reye":220,"mouth":328,"cheek":400}}],"voice_78":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":101,"reye":202,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":12,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":17,"face":{"leye":119,"reye":219,"mouth":311,"cheek":402}}],"voice_79":[{"frame":0,"face":{"leye":119,"reye":219,"mouth":311,"cheek":402}},{"frame":1,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":16,"face":{"leye":115,"reye":215,"mouth":307,"cheek":400}},{"frame":19,"face":{"leye":115,"reye":215,"mouth":314,"cheek":400}}],"voice_80":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":5,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":9,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":13,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":17,"face":{"leye":116,"reye":216,"mouth":326,"cheek":402}}],"voice_81":[{"frame":0,"face":{"leye":116,"reye":216,"mouth":315,"cheek":400}},{"frame":3,"face":{"leye":116,"reye":216,"mouth":308,"cheek":400}},{"frame":6,"face":{"leye":116,"reye":216,"mouth":314,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":314,"cheek":400}},{"frame":10,"face":{"leye":110,"reye":210,"mouth":303,"cheek":400}},{"frame":16,"face":{"leye":115,"reye":215,"mouth":326,"cheek":402}},{"frame":20,"face":{"leye":115,"reye":215,"mouth":314,"cheek":402}}],"voice_82":[{"frame":0,"face":{"leye":116,"reye":216,"mouth":315,"cheek":400}},{"frame":3,"face":{"leye":116,"reye":216,"mouth":308,"cheek":402}},{"frame":6,"face":{"leye":116,"reye":216,"mouth":314,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":314,"cheek":400}},{"frame":10,"face":{"leye":110,"reye":210,"mouth":303,"cheek":400}},{"frame":16,"face":{"leye":114,"reye":214,"mouth":308,"cheek":400}},{"frame":19,"face":{"leye":114,"reye":214,"mouth":0,"cheek":400}},{"frame":21,"face":{"leye":114,"reye":214,"mouth":308,"cheek":400}}],"voice_83":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":301,"cheek":400}},{"frame":16,"face":{"leye":114,"reye":214,"mouth":308,"cheek":400}},{"frame":19,"face":{"leye":114,"reye":214,"mouth":315,"cheek":400}},{"frame":22,"face":{"leye":114,"reye":214,"mouth":308,"cheek":400}},{"frame":24,"face":{"leye":114,"reye":214,"mouth":315,"cheek":400}}],"voice_84":[{"frame":0,"face":{"leye":116,"reye":216,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":116,"reye":216,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":116,"reye":216,"mouth":311,"cheek":400}},{"frame":14,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":18,"face":{"leye":121,"reye":210,"mouth":304,"cheek":402}},{"frame":19,"face":{"leye":121,"reye":221,"mouth":304,"cheek":402}},{"frame":21,"face":{"leye":121,"reye":221,"mouth":311,"cheek":402}},{"frame":24,"face":{"leye":121,"reye":221,"mouth":304,"cheek":402}},{"frame":26,"face":{"leye":121,"reye":221,"mouth":311,"cheek":402}}],"voice_85":[{"frame":0,"face":{"leye":121,"reye":221,"mouth":322,"cheek":402}},{"frame":4,"face":{"leye":121,"reye":221,"mouth":303,"cheek":402}},{"frame":9,"face":{"leye":121,"reye":221,"mouth":316,"cheek":402}},{"frame":12,"face":{"leye":121,"reye":221,"mouth":301,"cheek":402}},{"frame":19,"face":{"leye":118,"reye":218,"mouth":301,"cheek":400}}],"voice_86":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}},{"frame":3,"face":{"leye":101,"reye":201,"mouth":301,"cheek":402}},{"frame":6,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":319,"cheek":402}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":301,"cheek":402}},{"frame":15,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":17,"face":{"leye":117,"reye":217,"mouth":314,"cheek":400}},{"frame":20,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":21,"face":{"leye":117,"reye":217,"mouth":314,"cheek":400}}],"voice_87":[{"frame":0,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":2,"face":{"leye":117,"reye":217,"mouth":328,"cheek":400}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":328,"cheek":400}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":322,"cheek":400}},{"frame":9,"face":{"leye":106,"reye":206,"mouth":322,"cheek":400}},{"frame":11,"face":{"leye":106,"reye":206,"mouth":328,"cheek":400}},{"frame":16,"face":{"leye":108,"reye":209,"mouth":324,"cheek":400}},{"frame":18,"face":{"leye":108,"reye":209,"mouth":315,"cheek":400}},{"frame":21,"face":{"leye":108,"reye":209,"mouth":324,"cheek":400}},{"frame":23,"face":{"leye":108,"reye":209,"mouth":315,"cheek":400}}],"voice_88":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":3,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":7,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":16,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":18,"face":{"leye":110,"reye":210,"mouth":313,"cheek":402}},{"frame":21,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":23,"face":{"leye":110,"reye":210,"mouth":313,"cheek":402}},{"frame":26,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}}],"voice_89":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":13,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":19,"face":{"leye":102,"reye":202,"mouth":302,"cheek":402}},{"frame":21,"face":{"leye":102,"reye":202,"mouth":311,"cheek":402}},{"frame":24,"face":{"leye":102,"reye":202,"mouth":302,"cheek":402}},{"frame":25,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":26,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}}],"voice_90":[{"frame":0,"face":{"leye":108,"reye":208,"mouth":322,"cheek":400}},{"frame":3,"face":{"leye":108,"reye":208,"mouth":301,"cheek":400}},{"frame":6,"face":{"leye":108,"reye":208,"mouth":322,"cheek":400}},{"frame":13,"face":{"leye":108,"reye":208,"mouth":301,"cheek":400}},{"frame":18,"face":{"leye":108,"reye":208,"mouth":319,"cheek":400}},{"frame":22,"face":{"leye":108,"reye":208,"mouth":315,"cheek":400}},{"frame":27,"face":{"leye":108,"reye":208,"mouth":319,"cheek":400}},{"frame":30,"face":{"leye":108,"reye":208,"mouth":315,"cheek":400}}],"voice_91":[{"frame":0,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":2,"face":{"leye":117,"reye":217,"mouth":328,"cheek":400}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":328,"cheek":400}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":322,"cheek":400}},{"frame":9,"face":{"leye":106,"reye":206,"mouth":322,"cheek":400}},{"frame":11,"face":{"leye":106,"reye":206,"mouth":328,"cheek":400}},{"frame":16,"face":{"leye":119,"reye":220,"mouth":315,"cheek":400}}],"voice_92":[{"frame":0,"face":{"leye":116,"reye":216,"mouth":322,"cheek":402}},{"frame":3,"face":{"leye":116,"reye":216,"mouth":303,"cheek":402}},{"frame":8,"face":{"leye":116,"reye":216,"mouth":316,"cheek":402}},{"frame":11,"face":{"leye":116,"reye":216,"mouth":301,"cheek":402}},{"frame":18,"face":{"leye":114,"reye":214,"mouth":315,"cheek":400}}],"voice_93":[{"frame":0,"face":{"leye":119,"reye":220,"mouth":314,"cheek":400}},{"frame":3,"face":{"leye":119,"reye":220,"mouth":328,"cheek":400}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":314,"cheek":400}},{"frame":10,"face":{"leye":107,"reye":207,"mouth":314,"cheek":400}},{"frame":12,"face":{"leye":107,"reye":207,"mouth":328,"cheek":400}},{"frame":16,"face":{"leye":108,"reye":209,"mouth":324,"cheek":400}},{"frame":18,"face":{"leye":108,"reye":209,"mouth":315,"cheek":400}},{"frame":21,"face":{"leye":108,"reye":209,"mouth":324,"cheek":400}},{"frame":23,"face":{"leye":108,"reye":209,"mouth":315,"cheek":400}}],"voice_94":[{"frame":0,"face":{"leye":108,"reye":209,"mouth":314,"cheek":400}},{"frame":4,"face":{"leye":108,"reye":209,"mouth":303,"cheek":400}},{"frame":8,"face":{"leye":108,"reye":209,"mouth":314,"cheek":400}},{"frame":14,"face":{"leye":108,"reye":209,"mouth":328,"cheek":400}},{"frame":19,"face":{"leye":119,"reye":220,"mouth":324,"cheek":400}},{"frame":21,"face":{"leye":119,"reye":220,"mouth":314,"cheek":400}},{"frame":23,"face":{"leye":119,"reye":220,"mouth":324,"cheek":400}},{"frame":25,"face":{"leye":119,"reye":220,"mouth":314,"cheek":400}}],"voice_95":[{"frame":0,"face":{"leye":108,"reye":208,"mouth":314,"cheek":400}},{"frame":3,"face":{"leye":108,"reye":208,"mouth":301,"cheek":400}},{"frame":8,"face":{"leye":108,"reye":208,"mouth":314,"cheek":400}},{"frame":15,"face":{"leye":108,"reye":208,"mouth":301,"cheek":400}},{"frame":21,"face":{"leye":108,"reye":208,"mouth":324,"cheek":400}},{"frame":23,"face":{"leye":108,"reye":208,"mouth":314,"cheek":400}},{"frame":25,"face":{"leye":108,"reye":208,"mouth":324,"cheek":400}},{"frame":27,"face":{"leye":108,"reye":208,"mouth":314,"cheek":400}}],"voice_96":[{"frame":0,"face":{"leye":106,"reye":206,"mouth":315,"cheek":400}},{"frame":3,"face":{"leye":106,"reye":206,"mouth":324,"cheek":400}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":324,"cheek":400}},{"frame":9,"face":{"leye":110,"reye":210,"mouth":314,"cheek":400}},{"frame":10,"face":{"leye":108,"reye":208,"mouth":314,"cheek":400}},{"frame":13,"face":{"leye":108,"reye":208,"mouth":324,"cheek":400}},{"frame":19,"face":{"leye":117,"reye":217,"mouth":314,"cheek":400}},{"frame":23,"face":{"leye":117,"reye":217,"mouth":324,"cheek":400}},{"frame":26,"face":{"leye":117,"reye":217,"mouth":314,"cheek":400}},{"frame":29,"face":{"leye":117,"reye":217,"mouth":324,"cheek":400}},{"frame":31,"face":{"leye":108,"reye":208,"mouth":324,"cheek":400}}],"voice_97":[{"frame":0,"face":{"leye":117,"reye":217,"mouth":324,"cheek":400}},{"frame":3,"face":{"leye":117,"reye":217,"mouth":303,"cheek":400}},{"frame":7,"face":{"leye":117,"reye":217,"mouth":324,"cheek":400}},{"frame":20,"face":{"leye":108,"reye":208,"mouth":323,"cheek":400}},{"frame":20,"face":{"leye":108,"reye":208,"mouth":324,"cheek":400}},{"frame":25,"face":{"leye":108,"reye":208,"mouth":323,"cheek":400}},{"frame":29,"face":{"leye":108,"reye":208,"mouth":324,"cheek":400}}],"voice_98":[{"frame":0,"face":{"leye":117,"reye":217,"mouth":324,"cheek":400}},{"frame":2,"face":{"leye":117,"reye":217,"mouth":303,"cheek":400}},{"frame":7,"face":{"leye":117,"reye":217,"mouth":324,"cheek":400}},{"frame":10,"face":{"leye":110,"reye":210,"mouth":324,"cheek":400}},{"frame":12,"face":{"leye":110,"reye":210,"mouth":303,"cheek":400}},{"frame":18,"face":{"leye":108,"reye":208,"mouth":315,"cheek":400}},{"frame":24,"face":{"leye":108,"reye":208,"mouth":301,"cheek":400}}],"voice_99":[{"frame":0,"face":{"leye":116,"reye":216,"mouth":324,"cheek":402}},{"frame":3,"face":{"leye":116,"reye":216,"mouth":303,"cheek":402}},{"frame":8,"face":{"leye":116,"reye":216,"mouth":316,"cheek":402}},{"frame":11,"face":{"leye":116,"reye":216,"mouth":301,"cheek":402}},{"frame":18,"face":{"leye":110,"reye":210,"mouth":319,"cheek":402}}],"voice_100":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":13,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":19,"face":{"leye":119,"reye":220,"mouth":322,"cheek":400}}],"voice_101":[{"frame":0,"face":{"leye":117,"reye":217,"mouth":324,"cheek":400}},{"frame":3,"face":{"leye":117,"reye":217,"mouth":328,"cheek":400}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":328,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":324,"cheek":400}},{"frame":10,"face":{"leye":106,"reye":206,"mouth":324,"cheek":400}},{"frame":12,"face":{"leye":106,"reye":206,"mouth":328,"cheek":400}},{"frame":17,"face":{"leye":119,"reye":220,"mouth":315,"cheek":400}}],"voice_102":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":312,"cheek":402}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":9,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":302,"cheek":402}},{"frame":16,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":24,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}}],"voice_103":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":14,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":22,"face":{"leye":110,"reye":210,"mouth":302,"cheek":404}},{"frame":26,"face":{"leye":110,"reye":210,"mouth":321,"cheek":404}}],"voice_104":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":14,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}},{"frame":20,"face":{"leye":107,"reye":207,"mouth":306,"cheek":402}},{"frame":24,"face":{"leye":107,"reye":207,"mouth":311,"cheek":402}}],"voice_105":[{"frame":0,"face":{"leye":106,"reye":206,"mouth":324,"cheek":402}},{"frame":2,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":9,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":11,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":17,"face":{"leye":110,"reye":210,"mouth":312,"cheek":402}}],"voice_106":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":13,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":19,"face":{"leye":127,"reye":227,"mouth":312,"cheek":402}},{"frame":21,"face":{"leye":127,"reye":227,"mouth":310,"cheek":402}},{"frame":23,"face":{"leye":127,"reye":227,"mouth":312,"cheek":402}},{"frame":25,"face":{"leye":127,"reye":227,"mouth":310,"cheek":402}}],"voice_107":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":312,"cheek":402}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":9,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":302,"cheek":402}},{"frame":16,"face":{"leye":119,"reye":219,"mouth":312,"cheek":402}},{"frame":18,"face":{"leye":119,"reye":219,"mouth":311,"cheek":402}},{"frame":28,"face":{"leye":119,"reye":219,"mouth":302,"cheek":402}}],"voice_108":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":4,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}},{"frame":9,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":15,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}},{"frame":22,"face":{"leye":110,"reye":210,"mouth":312,"cheek":404}},{"frame":25,"face":{"leye":110,"reye":210,"mouth":311,"cheek":404}},{"frame":27,"face":{"leye":110,"reye":210,"mouth":312,"cheek":404}},{"frame":29,"face":{"leye":110,"reye":210,"mouth":311,"cheek":404}},{"frame":38,"face":{"leye":110,"reye":210,"mouth":302,"cheek":404}}],"voice_109":[{"frame":0,"face":{"leye":106,"reye":206,"mouth":322,"cheek":402}},{"frame":2,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":9,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":11,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":17,"face":{"leye":119,"reye":220,"mouth":321,"cheek":402}},{"frame":21,"face":{"leye":119,"reye":220,"mouth":311,"cheek":402}},{"frame":30,"face":{"leye":119,"reye":220,"mouth":302,"cheek":402}}],"voice_110":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}},{"frame":3,"face":{"leye":101,"reye":201,"mouth":301,"cheek":402}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":319,"cheek":402}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":301,"cheek":402}},{"frame":15,"face":{"leye":110,"reye":210,"mouth":321,"cheek":402}},{"frame":18,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}},{"frame":20,"face":{"leye":110,"reye":210,"mouth":321,"cheek":402}},{"frame":24,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}}],"voice_111":[{"frame":0,"face":{"leye":116,"reye":216,"mouth":311,"cheek":400}},{"frame":3,"face":{"leye":116,"reye":216,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":116,"reye":216,"mouth":311,"cheek":400}},{"frame":13,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":18,"face":{"leye":106,"reye":206,"mouth":317,"cheek":404}}],"voice_112":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":3,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":127,"reye":227,"mouth":310,"cheek":402}}],"voice_113":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":3,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":16,"face":{"leye":106,"reye":206,"mouth":306,"cheek":402}},{"frame":19,"face":{"leye":106,"reye":206,"mouth":0,"cheek":402}},{"frame":21,"face":{"leye":106,"reye":206,"mouth":306,"cheek":402}}],"voice_114":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":127,"reye":227,"mouth":302,"cheek":402}}],"voice_115":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":312,"cheek":402}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":9,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":302,"cheek":402}},{"frame":16,"face":{"leye":107,"reye":207,"mouth":319,"cheek":402}},{"frame":20,"face":{"leye":107,"reye":207,"mouth":306,"cheek":402}}],"voice_116":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":13,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":16,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":20,"face":{"leye":106,"reye":206,"mouth":310,"cheek":402}},{"frame":27,"face":{"leye":106,"reye":206,"mouth":302,"cheek":404}},{"frame":33,"face":{"leye":106,"reye":206,"mouth":310,"cheek":404}}],"voice_117":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":4,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":12,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":16,"face":{"leye":103,"reye":203,"mouth":321,"cheek":404}},{"frame":17,"face":{"leye":103,"reye":203,"mouth":311,"cheek":404}},{"frame":20,"face":{"leye":103,"reye":203,"mouth":321,"cheek":404}},{"frame":21,"face":{"leye":103,"reye":203,"mouth":311,"cheek":404}},{"frame":24,"face":{"leye":103,"reye":203,"mouth":321,"cheek":404}},{"frame":26,"face":{"leye":103,"reye":203,"mouth":310,"cheek":404}}],"voice_118":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}},{"frame":2,"face":{"leye":101,"reye":201,"mouth":301,"cheek":402}},{"frame":5,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":319,"cheek":402}},{"frame":10,"face":{"leye":101,"reye":201,"mouth":301,"cheek":402}},{"frame":15,"face":{"leye":107,"reye":207,"mouth":309,"cheek":400}}],"voice_119":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":2,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":12,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":18,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":21,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":25,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":28,"face":{"leye":110,"reye":210,"mouth":309,"cheek":400}}],"voice_120":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":312,"cheek":402}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":9,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":12,"face":{"leye":101,"reye":201,"mouth":302,"cheek":402}},{"frame":16,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":19,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}},{"frame":21,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":23,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}}],"voice_121":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":14,"face":{"leye":110,"reye":210,"mouth":304,"cheek":402}},{"frame":20,"face":{"leye":103,"reye":203,"mouth":319,"cheek":402}},{"frame":22,"face":{"leye":103,"reye":203,"mouth":311,"cheek":402}},{"frame":26,"face":{"leye":103,"reye":203,"mouth":319,"cheek":402}},{"frame":27,"face":{"leye":103,"reye":203,"mouth":311,"cheek":402}}],"voice_122":[{"frame":0,"face":{"leye":106,"reye":206,"mouth":324,"cheek":402}},{"frame":1,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":324,"cheek":402}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":9,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":11,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":17,"face":{"leye":106,"reye":206,"mouth":319,"cheek":404}},{"frame":18,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":20,"face":{"leye":106,"reye":206,"mouth":319,"cheek":404}},{"frame":22,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":24,"face":{"leye":106,"reye":206,"mouth":319,"cheek":404}},{"frame":26,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":28,"face":{"leye":106,"reye":206,"mouth":314,"cheek":404}}],"voice_123":[{"frame":0,"face":{"leye":108,"reye":208,"mouth":315,"cheek":400}},{"frame":5,"face":{"leye":108,"reye":208,"mouth":326,"cheek":400}},{"frame":19,"face":{"leye":108,"reye":208,"mouth":319,"cheek":400}},{"frame":22,"face":{"leye":108,"reye":208,"mouth":324,"cheek":400}},{"frame":25,"face":{"leye":108,"reye":208,"mouth":314,"cheek":400}},{"frame":28,"face":{"leye":108,"reye":208,"mouth":301,"cheek":400}},{"frame":30,"face":{"leye":108,"reye":208,"mouth":314,"cheek":400}},{"frame":34,"face":{"leye":108,"reye":208,"mouth":301,"cheek":400}}],"voice_124":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":4,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":14,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":22,"face":{"leye":111,"reye":211,"mouth":302,"cheek":402}},{"frame":24,"face":{"leye":111,"reye":211,"mouth":313,"cheek":402}},{"frame":26,"face":{"leye":111,"reye":211,"mouth":302,"cheek":402}},{"frame":30,"face":{"leye":111,"reye":211,"mouth":313,"cheek":402}},{"frame":33,"face":{"leye":111,"reye":211,"mouth":302,"cheek":402}}],"voice_125":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}},{"frame":3,"face":{"leye":101,"reye":201,"mouth":301,"cheek":402}},{"frame":6,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":319,"cheek":402}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":301,"cheek":402}},{"frame":15,"face":{"leye":111,"reye":211,"mouth":301,"cheek":400}},{"frame":16,"face":{"leye":111,"reye":211,"mouth":311,"cheek":400}},{"frame":17,"face":{"leye":126,"reye":226,"mouth":311,"cheek":400}},{"frame":19,"face":{"leye":111,"reye":211,"mouth":311,"cheek":400}},{"frame":20,"face":{"leye":126,"reye":226,"mouth":311,"cheek":400}}],"voice_126":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":3,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":102,"reye":202,"mouth":310,"cheek":400}},{"frame":23,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}}],"voice_127":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":4,"face":{"leye":111,"reye":211,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":111,"reye":211,"mouth":311,"cheek":400}},{"frame":8,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":102,"reye":202,"mouth":310,"cheek":400}},{"frame":18,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":19,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":21,"face":{"leye":116,"reye":216,"mouth":304,"cheek":400}}],"voice_128":[{"frame":0,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":3,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":7,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":14,"face":{"leye":101,"reye":201,"mouth":310,"cheek":400}},{"frame":15,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":18,"face":{"leye":101,"reye":206,"mouth":309,"cheek":400}}],"voice_129":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":101,"reye":206,"mouth":310,"cheek":402}}],"voice_130":[{"frame":0,"face":{"leye":116,"reye":216,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":116,"reye":216,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":116,"reye":216,"mouth":311,"cheek":400}},{"frame":12,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":17,"face":{"leye":103,"reye":203,"mouth":312,"cheek":400}},{"frame":19,"face":{"leye":103,"reye":203,"mouth":311,"cheek":400}},{"frame":21,"face":{"leye":107,"reye":207,"mouth":316,"cheek":400}},{"frame":22,"face":{"leye":107,"reye":207,"mouth":306,"cheek":400}},{"frame":24,"face":{"leye":107,"reye":207,"mouth":311,"cheek":400}},{"frame":26,"face":{"leye":107,"reye":207,"mouth":321,"cheek":400}},{"frame":28,"face":{"leye":102,"reye":206,"mouth":310,"cheek":400}}],"voice_131":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":3,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":17,"face":{"leye":105,"reye":205,"mouth":312,"cheek":400}},{"frame":18,"face":{"leye":105,"reye":205,"mouth":311,"cheek":400}},{"frame":20,"face":{"leye":105,"reye":205,"mouth":321,"cheek":400}},{"frame":22,"face":{"leye":105,"reye":205,"mouth":304,"cheek":400}}],"voice_132":[{"frame":0,"face":{"leye":106,"reye":206,"mouth":314,"cheek":404}},{"frame":3,"face":{"leye":106,"reye":206,"mouth":328,"cheek":404}},{"frame":7,"face":{"leye":106,"reye":206,"mouth":314,"cheek":404}},{"frame":12,"face":{"leye":106,"reye":206,"mouth":328,"cheek":404}},{"frame":15,"face":{"leye":106,"reye":206,"mouth":315,"cheek":400}},{"frame":17,"face":{"leye":106,"reye":206,"mouth":303,"cheek":400}},{"frame":18,"face":{"leye":106,"reye":206,"mouth":315,"cheek":400}},{"frame":19,"face":{"leye":106,"reye":206,"mouth":303,"cheek":400}},{"frame":20,"face":{"leye":106,"reye":206,"mouth":315,"cheek":400}}],"voice_133":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":3,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":7,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":8,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":12,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":16,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":18,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":20,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}}],"voice_134":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":101,"reye":206,"mouth":317,"cheek":405}},{"frame":17,"face":{"leye":101,"reye":206,"mouth":302,"cheek":405}},{"frame":20,"face":{"leye":106,"reye":201,"mouth":317,"cheek":405}},{"frame":22,"face":{"leye":106,"reye":201,"mouth":302,"cheek":405}}],"voice_135":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":3,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":8,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":12,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":102,"reye":202,"mouth":304,"cheek":405}},{"frame":16,"face":{"leye":105,"reye":205,"mouth":330,"cheek":405}},{"frame":19,"face":{"leye":105,"reye":205,"mouth":331,"cheek":405}},{"frame":21,"face":{"leye":105,"reye":205,"mouth":330,"cheek":405}},{"frame":23,"face":{"leye":105,"reye":205,"mouth":331,"cheek":405}}],"voice_136":[{"frame":0,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":7,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":14,"face":{"leye":101,"reye":206,"mouth":332,"cheek":405}}],"voice_137":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":3,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":106,"reye":202,"mouth":310,"cheek":400}},{"frame":22,"face":{"leye":106,"reye":202,"mouth":304,"cheek":400}}],"voice_138":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":4,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":107,"reye":207,"mouth":310,"cheek":402}}],"voice_139":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":8,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":13,"face":{"leye":116,"reye":216,"mouth":311,"cheek":404}},{"frame":15,"face":{"leye":116,"reye":216,"mouth":321,"cheek":404}},{"frame":17,"face":{"leye":116,"reye":216,"mouth":311,"cheek":404}},{"frame":19,"face":{"leye":116,"reye":216,"mouth":302,"cheek":404}}],"voice_140":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":3,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":11,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":102,"reye":206,"mouth":310,"cheek":400}},{"frame":21,"face":{"leye":102,"reye":206,"mouth":306,"cheek":400}}],"voice_141":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":1,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":3,"face":{"leye":111,"reye":211,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":111,"reye":211,"mouth":311,"cheek":400}},{"frame":7,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":10,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":14,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":16,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":17,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":20,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":23,"face":{"leye":106,"reye":206,"mouth":312,"cheek":400}},{"frame":24,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":27,"face":{"leye":106,"reye":206,"mouth":310,"cheek":402}}],"voice_142":[{"frame":1,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":2,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":4,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":6,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":9,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":13,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":15,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}},{"frame":16,"face":{"leye":101,"reye":206,"mouth":311,"cheek":402}}]},"musicDb":[{"id":200001,"title":"TOKIMEKI Runners (心动逐梦人)","cover":"tkmk","artist":"虹ヶ咲学園スクールアイドル同好会","description":"手机游戏《Love Live!学园偶像祭 ALL STARS》主题曲，同时也是首张 专辑的主打歌。这首歌既是虹咲学园学园偶像同好会的起点，也是Live的定番歌曲。开场动画中由μ's、Aqours以及虹咲学园的三校27人一同表演的场面也令人印象深刻。"},{"id":209000,"title":"ツナガルコネクト (相连的connect)","cover":"solo0","artist":"天王寺璃奈","description":"TV动画《Love Live! 虹咲学园学园偶像同好会》第一季第6话插曲。不擅 表达感情的璃奈完全活用“小璃奈板”展开Solo Live时首度演出的歌曲。 歌词用“［Ctrl］+［Z］又没用”表现日常情境无法取消已说出的话，配上衬托擅长操作机械的璃奈的垫音，完整展现了璃奈独有特色。"},{"id":209001,"title":"ドキピポ☆エモーション (心跳☆加速)","cover":"solo1","artist":"天王寺璃奈","description":"虹咲学园学园偶像同好会首张专辑收录曲。SIFAS剧情2章插曲。璃奈的第一首Solo曲。描述的是不擅表达感情的璃奈在装上“小璃奈板”时的心境。整体而言是首电子音效突出的电波歌曲，“小璃奈板”呼声也是大家High起的定番桥段。"},{"id":209002,"title":"テレテレパシー (心灵心灵感应)","cover":"solo2","artist":"天王寺璃奈","description":"虹咲学园学园偶像同好会第二张专辑收录曲。SIFAS璃奈羁绊剧情12话插曲。在羁绊剧情中，璃奈首度卸下“小璃奈板”歌唱的歌曲。羁绊剧情第12话释出时引起了相当大的讨论。Live时挥舞心电感应杖的舞蹈也令人印象深刻。"},{"id":209003,"title":"アナログハート (电波之心)","cover":"solo3","artist":"天王寺璃奈","description":"虹咲学园学园偶像同好会第三张专辑收录曲。SIFAS璃奈羁绊剧情21话插曲。SIFAS羁绊剧情中，粉丝俱乐部活动时为了“想要静静地聆听璃奈的歌声”的粉丝们，选择线上转播的歌曲。曲中寄托了璃奈想要跟大家更加友好，更加密切的心愿。"},{"id":209004,"title":"First Love Again (再一次初恋)","cover":"solo4","artist":"天王寺璃奈","description":"虹咲学园学园偶像同好会第四张专辑收录曲。SIFAS璃奈羁绊剧情27话插曲。在羁绊剧情中，负责为电玩研究部拍的校内影像祭电影制作主题曲的璃奈挑战作曲的歌曲。描写记忆只能维持一天的主角心境，温柔窝心的抒情歌曲。"},{"id":209005,"title":"私はマグネット (我是磁石)","cover":"solo5","artist":"天王寺璃奈","description":"虹咲学园学园偶像同好会第五张专辑收录曲。由受邀参加学园偶像祭2的“学园偶像的日常”之“情歌嘉年华”的虹咲学园成员制作。因为从你那里得到了爱而获得救赎的璃奈。这首歌融合了澎湃的福音歌曲旋律，描绘出璃奈那辽阔的世界。"},{"id":200002,"title":"Love U my friends (爱你我的朋友们)","cover":"lumf","artist":"虹ヶ咲学園スクールアイドル同好会","description":"虹咲学园学园偶像同好会第二张专辑的主打歌，也是虹咲首度全员穿上相同舞台装的歌曲。开头成员们各自被打上自己代表色的姿态令人难忘。情感丰沛的吉他主奏，以及满满对你的感谢的歌词都令人热泪满盈。"}],"musicTimelines":{"lumf":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":69,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":112,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":117,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":127,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":131,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":141,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":146,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":160,"face":{"leye":110,"reye":210,"mouth":310,"cheek":400}},{"frame":164,"face":{"leye":101,"reye":201,"mouth":310,"cheek":400}},{"frame":168,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":186,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":193,"face":{"leye":101,"reye":206,"mouth":304,"cheek":402}},{"frame":196,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":200,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":202,"face":{"leye":101,"reye":201,"mouth":310,"cheek":400}},{"frame":204,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":207,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":208,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":212,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":214,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":216,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":218,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":221,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":223,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":226,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":228,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":230,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":234,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":238,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":245,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":249,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":261,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":271,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":275,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":277,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":279,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":283,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":284,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":302,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":304,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":306,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":308,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":314,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":317,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":334,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":401,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":404,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":407,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":411,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":413,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":415,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":417,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":418,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":422,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":425,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":432,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":437,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":439,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":444,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":488,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":489,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":491,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":492,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":493,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":497,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":501,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":503,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":505,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":506,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":507,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":514,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":524,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":532,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":533,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":535,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":537,"face":{"leye":110,"reye":210,"mouth":313,"cheek":400}},{"frame":539,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":545,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":554,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":558,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":563,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":566,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":568,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":570,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":571,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":574,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":578,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":580,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":588,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":592,"face":{"leye":101,"reye":201,"mouth":310,"cheek":400}},{"frame":594,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":597,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":602,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":604,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":610,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":612,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":614,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":620,"face":{"leye":101,"reye":201,"mouth":310,"cheek":400}},{"frame":626,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":629,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":634,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":637,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":644,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":646,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":655,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":657,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":658,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":661,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":669,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":671,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":682,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":684,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":686,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":688,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":694,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":702,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":705,"face":{"leye":101,"reye":201,"mouth":310,"cheek":400}},{"frame":707,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":709,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":711,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":713,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":714,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":717,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":724,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":726,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":727,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":729,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":735,"face":{"leye":101,"reye":201,"mouth":310,"cheek":400}},{"frame":737,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":740,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":743,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":746,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":751,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":756,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":757,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":760,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":763,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":767,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":769,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":773,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":776,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":778,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":786,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":791,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":794,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":820,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":823,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":828,"face":{"leye":110,"reye":210,"mouth":310,"cheek":400}},{"frame":829,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":830,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":831,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":832,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":833,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":834,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":835,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":836,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":838,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":839,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":842,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":866,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":875,"face":{"leye":110,"reye":210,"mouth":313,"cheek":400}},{"frame":881,"face":{"leye":101,"reye":201,"mouth":313,"cheek":400}},{"frame":889,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":895,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":937,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":941,"face":{"leye":101,"reye":206,"mouth":304,"cheek":402}},{"frame":946,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":978,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":1023,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":1031,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}}],"solo0":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":5,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":22,"face":{"leye":101,"reye":201,"mouth":310,"cheek":400}},{"frame":34,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":35,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}},{"frame":36,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":37,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":39,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":40,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":42,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":46,"face":{"leye":106,"reye":206,"mouth":317,"cheek":400}},{"frame":47,"face":{"leye":106,"reye":206,"mouth":319,"cheek":403}},{"frame":48,"face":{"leye":106,"reye":206,"mouth":317,"cheek":403}},{"frame":52,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":55,"face":{"leye":106,"reye":206,"mouth":310,"cheek":403}},{"frame":57,"face":{"leye":106,"reye":206,"mouth":302,"cheek":403}},{"frame":58,"face":{"leye":106,"reye":206,"mouth":317,"cheek":403}},{"frame":59,"face":{"leye":102,"reye":202,"mouth":317,"cheek":403}},{"frame":60,"face":{"leye":106,"reye":206,"mouth":302,"cheek":400}},{"frame":64,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":67,"face":{"leye":110,"reye":210,"mouth":316,"cheek":403}},{"frame":68,"face":{"leye":102,"reye":202,"mouth":310,"cheek":400}},{"frame":72,"face":{"leye":106,"reye":206,"mouth":319,"cheek":400}},{"frame":73,"face":{"leye":106,"reye":206,"mouth":316,"cheek":400}},{"frame":75,"face":{"leye":110,"reye":210,"mouth":316,"cheek":400}},{"frame":76,"face":{"leye":101,"reye":202,"mouth":316,"cheek":400}},{"frame":79,"face":{"leye":106,"reye":206,"mouth":306,"cheek":400}},{"frame":80,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":82,"face":{"leye":105,"reye":205,"mouth":323,"cheek":403}},{"frame":85,"face":{"leye":105,"reye":205,"mouth":302,"cheek":403}},{"frame":87,"face":{"leye":102,"reye":202,"mouth":302,"cheek":403}},{"frame":88,"face":{"leye":107,"reye":207,"mouth":311,"cheek":403}},{"frame":93,"face":{"leye":107,"reye":207,"mouth":304,"cheek":403}},{"frame":117,"face":{"leye":106,"reye":202,"mouth":311,"cheek":403}},{"frame":144,"face":{"leye":106,"reye":202,"mouth":304,"cheek":403}},{"frame":149,"face":{"leye":107,"reye":207,"mouth":304,"cheek":403}},{"frame":168,"face":{"leye":107,"reye":207,"mouth":311,"cheek":403}},{"frame":172,"face":{"leye":107,"reye":207,"mouth":304,"cheek":403}},{"frame":182,"face":{"leye":105,"reye":205,"mouth":323,"cheek":403}},{"frame":183,"face":{"leye":105,"reye":205,"mouth":311,"cheek":403}},{"frame":184,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":186,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":187,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":192,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":196,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":198,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":201,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":203,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":206,"face":{"leye":119,"reye":219,"mouth":316,"cheek":400}},{"frame":207,"face":{"leye":119,"reye":219,"mouth":319,"cheek":400}},{"frame":210,"face":{"leye":119,"reye":219,"mouth":316,"cheek":400}},{"frame":214,"face":{"leye":119,"reye":219,"mouth":311,"cheek":400}},{"frame":217,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":221,"face":{"leye":106,"reye":206,"mouth":310,"cheek":400}},{"frame":223,"face":{"leye":101,"reye":201,"mouth":310,"cheek":400}},{"frame":224,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":226,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":230,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":235,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":238,"face":{"leye":111,"reye":211,"mouth":311,"cheek":400}},{"frame":244,"face":{"leye":111,"reye":211,"mouth":328,"cheek":400}},{"frame":251,"face":{"leye":119,"reye":219,"mouth":319,"cheek":400}},{"frame":253,"face":{"leye":119,"reye":219,"mouth":311,"cheek":400}},{"frame":254,"face":{"leye":107,"reye":207,"mouth":311,"cheek":400}},{"frame":256,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":258,"face":{"leye":117,"reye":217,"mouth":302,"cheek":400}},{"frame":259,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":261,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":262,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":267,"face":{"leye":117,"reye":217,"mouth":302,"cheek":400}},{"frame":268,"face":{"leye":117,"reye":217,"mouth":310,"cheek":400}},{"frame":272,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":276,"face":{"leye":117,"reye":217,"mouth":310,"cheek":400}},{"frame":277,"face":{"leye":110,"reye":210,"mouth":310,"cheek":400}},{"frame":279,"face":{"leye":119,"reye":220,"mouth":310,"cheek":400}},{"frame":280,"face":{"leye":119,"reye":220,"mouth":319,"cheek":400}},{"frame":281,"face":{"leye":119,"reye":220,"mouth":316,"cheek":400}},{"frame":284,"face":{"leye":119,"reye":220,"mouth":319,"cheek":400}},{"frame":287,"face":{"leye":119,"reye":220,"mouth":302,"cheek":400}},{"frame":288,"face":{"leye":119,"reye":220,"mouth":311,"cheek":400}},{"frame":292,"face":{"leye":119,"reye":220,"mouth":322,"cheek":400}},{"frame":297,"face":{"leye":119,"reye":220,"mouth":328,"cheek":400}},{"frame":304,"face":{"leye":106,"reye":206,"mouth":328,"cheek":402}},{"frame":305,"face":{"leye":106,"reye":206,"mouth":321,"cheek":402}},{"frame":306,"face":{"leye":107,"reye":207,"mouth":323,"cheek":402}},{"frame":309,"face":{"leye":107,"reye":207,"mouth":311,"cheek":402}},{"frame":310,"face":{"leye":107,"reye":207,"mouth":310,"cheek":402}},{"frame":311,"face":{"leye":110,"reye":210,"mouth":310,"cheek":403}},{"frame":312,"face":{"leye":119,"reye":219,"mouth":311,"cheek":402}},{"frame":317,"face":{"leye":119,"reye":219,"mouth":302,"cheek":402}},{"frame":320,"face":{"leye":119,"reye":219,"mouth":319,"cheek":402}},{"frame":327,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":328,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":332,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}},{"frame":334,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":339,"face":{"leye":122,"reye":222,"mouth":312,"cheek":400}},{"frame":340,"face":{"leye":122,"reye":222,"mouth":311,"cheek":400}},{"frame":342,"face":{"leye":122,"reye":222,"mouth":316,"cheek":400}},{"frame":345,"face":{"leye":122,"reye":222,"mouth":322,"cheek":400}},{"frame":346,"face":{"leye":110,"reye":210,"mouth":322,"cheek":400}},{"frame":347,"face":{"leye":106,"reye":206,"mouth":314,"cheek":403}},{"frame":349,"face":{"leye":106,"reye":206,"mouth":328,"cheek":403}},{"frame":350,"face":{"leye":106,"reye":206,"mouth":314,"cheek":403}},{"frame":352,"face":{"leye":106,"reye":206,"mouth":322,"cheek":403}},{"frame":356,"face":{"leye":106,"reye":206,"mouth":328,"cheek":403}},{"frame":360,"face":{"leye":106,"reye":206,"mouth":319,"cheek":403}},{"frame":361,"face":{"leye":116,"reye":216,"mouth":319,"cheek":402}},{"frame":367,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":368,"face":{"leye":116,"reye":216,"mouth":319,"cheek":402}},{"frame":369,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":373,"face":{"leye":116,"reye":216,"mouth":321,"cheek":402}},{"frame":375,"face":{"leye":116,"reye":216,"mouth":319,"cheek":402}},{"frame":378,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":379,"face":{"leye":116,"reye":216,"mouth":321,"cheek":402}},{"frame":380,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":382,"face":{"leye":116,"reye":216,"mouth":321,"cheek":402}},{"frame":384,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":386,"face":{"leye":116,"reye":216,"mouth":311,"cheek":400}},{"frame":387,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":388,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":390,"face":{"leye":117,"reye":217,"mouth":319,"cheek":400}},{"frame":392,"face":{"leye":117,"reye":217,"mouth":317,"cheek":400}},{"frame":393,"face":{"leye":117,"reye":217,"mouth":319,"cheek":400}},{"frame":397,"face":{"leye":117,"reye":217,"mouth":316,"cheek":400}},{"frame":398,"face":{"leye":117,"reye":217,"mouth":314,"cheek":400}},{"frame":401,"face":{"leye":106,"reye":206,"mouth":314,"cheek":400}},{"frame":401,"face":{"leye":106,"reye":206,"mouth":322,"cheek":400}},{"frame":407,"face":{"leye":119,"reye":219,"mouth":322,"cheek":400}},{"frame":408,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":409,"face":{"leye":108,"reye":209,"mouth":314,"cheek":400}},{"frame":417,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":419,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":422,"face":{"leye":117,"reye":217,"mouth":319,"cheek":400}},{"frame":424,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":428,"face":{"leye":119,"reye":220,"mouth":302,"cheek":400}},{"frame":429,"face":{"leye":119,"reye":220,"mouth":322,"cheek":400}},{"frame":432,"face":{"leye":119,"reye":220,"mouth":328,"cheek":400}},{"frame":444,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":446,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}},{"frame":448,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":450,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":452,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":454,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":456,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":468,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":469,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":470,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":471,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":472,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":474,"face":{"leye":110,"reye":210,"mouth":316,"cheek":400}},{"frame":475,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":476,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":477,"face":{"leye":107,"reye":207,"mouth":311,"cheek":400}},{"frame":478,"face":{"leye":107,"reye":207,"mouth":302,"cheek":400}},{"frame":480,"face":{"leye":107,"reye":207,"mouth":311,"cheek":400}},{"frame":481,"face":{"leye":101,"reye":201,"mouth":328,"cheek":400}},{"frame":483,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":484,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":486,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":487,"face":{"leye":108,"reye":209,"mouth":316,"cheek":400}},{"frame":490,"face":{"leye":108,"reye":209,"mouth":321,"cheek":400}},{"frame":495,"face":{"leye":108,"reye":209,"mouth":311,"cheek":400}},{"frame":497,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":498,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":507,"face":{"leye":101,"reye":201,"mouth":302,"cheek":402}},{"frame":509,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":511,"face":{"leye":119,"reye":219,"mouth":321,"cheek":402}},{"frame":516,"face":{"leye":119,"reye":219,"mouth":323,"cheek":402}},{"frame":517,"face":{"leye":119,"reye":219,"mouth":316,"cheek":402}},{"frame":520,"face":{"leye":119,"reye":219,"mouth":311,"cheek":402}},{"frame":523,"face":{"leye":119,"reye":219,"mouth":302,"cheek":402}},{"frame":525,"face":{"leye":119,"reye":219,"mouth":311,"cheek":402}},{"frame":527,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":539,"face":{"leye":106,"reye":202,"mouth":311,"cheek":403}},{"frame":545,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":549,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":550,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":552,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":555,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":556,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":558,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":559,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":560,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":562,"face":{"leye":106,"reye":206,"mouth":321,"cheek":402}},{"frame":564,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":565,"face":{"leye":106,"reye":206,"mouth":319,"cheek":402}},{"frame":567,"face":{"leye":101,"reye":201,"mouth":319,"cheek":403}},{"frame":569,"face":{"leye":101,"reye":201,"mouth":311,"cheek":403}},{"frame":570,"face":{"leye":101,"reye":201,"mouth":321,"cheek":403}},{"frame":571,"face":{"leye":101,"reye":201,"mouth":311,"cheek":403}},{"frame":572,"face":{"leye":101,"reye":201,"mouth":321,"cheek":403}},{"frame":574,"face":{"leye":106,"reye":206,"mouth":321,"cheek":403}},{"frame":575,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":577,"face":{"leye":106,"reye":206,"mouth":316,"cheek":403}},{"frame":578,"face":{"leye":110,"reye":210,"mouth":316,"cheek":403}},{"frame":579,"face":{"leye":101,"reye":201,"mouth":321,"cheek":403}},{"frame":581,"face":{"leye":101,"reye":201,"mouth":316,"cheek":403}},{"frame":583,"face":{"leye":101,"reye":201,"mouth":321,"cheek":403}},{"frame":586,"face":{"leye":101,"reye":201,"mouth":311,"cheek":403}},{"frame":589,"face":{"leye":101,"reye":201,"mouth":312,"cheek":403}},{"frame":589,"face":{"leye":101,"reye":201,"mouth":312,"cheek":403}},{"frame":591,"face":{"leye":101,"reye":201,"mouth":321,"cheek":403}},{"frame":597,"face":{"leye":101,"reye":201,"mouth":316,"cheek":403}},{"frame":600,"face":{"leye":106,"reye":206,"mouth":313,"cheek":403}},{"frame":604,"face":{"leye":110,"reye":210,"mouth":313,"cheek":403}},{"frame":605,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":606,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":607,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":609,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":615,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":616,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":619,"face":{"leye":102,"reye":202,"mouth":310,"cheek":400}},{"frame":620,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":624,"face":{"leye":110,"reye":210,"mouth":321,"cheek":403}},{"frame":627,"face":{"leye":110,"reye":210,"mouth":311,"cheek":403}},{"frame":629,"face":{"leye":110,"reye":210,"mouth":302,"cheek":403}},{"frame":634,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":636,"face":{"leye":106,"reye":206,"mouth":321,"cheek":403}},{"frame":637,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":639,"face":{"leye":106,"reye":206,"mouth":319,"cheek":403}},{"frame":643,"face":{"leye":106,"reye":206,"mouth":321,"cheek":403}},{"frame":644,"face":{"leye":105,"reye":205,"mouth":321,"cheek":403}},{"frame":646,"face":{"leye":105,"reye":205,"mouth":311,"cheek":403}},{"frame":648,"face":{"leye":105,"reye":205,"mouth":321,"cheek":403}},{"frame":650,"face":{"leye":105,"reye":205,"mouth":311,"cheek":403}},{"frame":651,"face":{"leye":105,"reye":205,"mouth":312,"cheek":403}},{"frame":656,"face":{"leye":102,"reye":202,"mouth":304,"cheek":403}},{"frame":657,"face":{"leye":102,"reye":202,"mouth":317,"cheek":403}},{"frame":658,"face":{"leye":110,"reye":210,"mouth":317,"cheek":403}},{"frame":660,"face":{"leye":119,"reye":219,"mouth":321,"cheek":403}},{"frame":662,"face":{"leye":106,"reye":206,"mouth":321,"cheek":403}},{"frame":665,"face":{"leye":119,"reye":219,"mouth":321,"cheek":403}},{"frame":671,"face":{"leye":119,"reye":219,"mouth":319,"cheek":403}},{"frame":673,"face":{"leye":119,"reye":219,"mouth":311,"cheek":403}},{"frame":675,"face":{"leye":119,"reye":219,"mouth":321,"cheek":403}},{"frame":678,"face":{"leye":119,"reye":219,"mouth":311,"cheek":403}},{"frame":679,"face":{"leye":119,"reye":219,"mouth":321,"cheek":403}},{"frame":681,"face":{"leye":119,"reye":219,"mouth":302,"cheek":403}},{"frame":682,"face":{"leye":119,"reye":219,"mouth":311,"cheek":403}},{"frame":684,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":686,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":687,"face":{"leye":110,"reye":210,"mouth":302,"cheek":403}},{"frame":689,"face":{"leye":102,"reye":202,"mouth":319,"cheek":403}},{"frame":690,"face":{"leye":106,"reye":202,"mouth":302,"cheek":403}},{"frame":691,"face":{"leye":106,"reye":202,"mouth":319,"cheek":403}},{"frame":692,"face":{"leye":106,"reye":202,"mouth":310,"cheek":403}},{"frame":694,"face":{"leye":102,"reye":202,"mouth":310,"cheek":403}},{"frame":696,"face":{"leye":102,"reye":202,"mouth":311,"cheek":403}},{"frame":697,"face":{"leye":102,"reye":206,"mouth":311,"cheek":403}},{"frame":698,"face":{"leye":102,"reye":206,"mouth":316,"cheek":403}},{"frame":699,"face":{"leye":102,"reye":206,"mouth":319,"cheek":403}},{"frame":700,"face":{"leye":102,"reye":206,"mouth":316,"cheek":403}},{"frame":702,"face":{"leye":110,"reye":210,"mouth":321,"cheek":403}},{"frame":704,"face":{"leye":119,"reye":219,"mouth":321,"cheek":403}},{"frame":709,"face":{"leye":119,"reye":219,"mouth":311,"cheek":403}},{"frame":714,"face":{"leye":110,"reye":210,"mouth":311,"cheek":403}},{"frame":715,"face":{"leye":119,"reye":219,"mouth":319,"cheek":403}},{"frame":718,"face":{"leye":119,"reye":219,"mouth":311,"cheek":403}},{"frame":722,"face":{"leye":119,"reye":219,"mouth":302,"cheek":403}},{"frame":724,"face":{"leye":119,"reye":219,"mouth":311,"cheek":403}},{"frame":727,"face":{"leye":106,"reye":201,"mouth":311,"cheek":403}},{"frame":729,"face":{"leye":106,"reye":201,"mouth":321,"cheek":403}},{"frame":730,"face":{"leye":106,"reye":201,"mouth":319,"cheek":403}},{"frame":734,"face":{"leye":106,"reye":201,"mouth":321,"cheek":403}},{"frame":736,"face":{"leye":106,"reye":201,"mouth":302,"cheek":403}},{"frame":737,"face":{"leye":106,"reye":201,"mouth":311,"cheek":403}},{"frame":738,"face":{"leye":106,"reye":201,"mouth":312,"cheek":403}},{"frame":740,"face":{"leye":106,"reye":201,"mouth":302,"cheek":403}},{"frame":742,"face":{"leye":101,"reye":201,"mouth":306,"cheek":403}},{"frame":743,"face":{"leye":101,"reye":201,"mouth":316,"cheek":403}},{"frame":744,"face":{"leye":101,"reye":201,"mouth":310,"cheek":403}},{"frame":747,"face":{"leye":101,"reye":201,"mouth":311,"cheek":403}},{"frame":748,"face":{"leye":101,"reye":201,"mouth":321,"cheek":403}},{"frame":752,"face":{"leye":101,"reye":201,"mouth":312,"cheek":403}},{"frame":753,"face":{"leye":101,"reye":201,"mouth":319,"cheek":403}},{"frame":754,"face":{"leye":101,"reye":201,"mouth":321,"cheek":403}},{"frame":757,"face":{"leye":101,"reye":201,"mouth":311,"cheek":403}},{"frame":762,"face":{"leye":101,"reye":201,"mouth":312,"cheek":403}},{"frame":765,"face":{"leye":106,"reye":206,"mouth":312,"cheek":403}},{"frame":774,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":776,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":777,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":778,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":780,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":781,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":783,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":784,"face":{"leye":106,"reye":206,"mouth":317,"cheek":400}},{"frame":785,"face":{"leye":106,"reye":206,"mouth":316,"cheek":403}},{"frame":786,"face":{"leye":106,"reye":206,"mouth":319,"cheek":403}},{"frame":787,"face":{"leye":106,"reye":206,"mouth":317,"cheek":403}},{"frame":790,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":794,"face":{"leye":106,"reye":206,"mouth":321,"cheek":403}},{"frame":796,"face":{"leye":106,"reye":206,"mouth":302,"cheek":403}},{"frame":797,"face":{"leye":110,"reye":210,"mouth":316,"cheek":403}},{"frame":799,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":801,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":803,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":804,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":805,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":806,"face":{"leye":102,"reye":202,"mouth":302,"cheek":400}},{"frame":807,"face":{"leye":102,"reye":202,"mouth":310,"cheek":400}},{"frame":809,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":811,"face":{"leye":102,"reye":202,"mouth":316,"cheek":400}},{"frame":816,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":818,"face":{"leye":110,"reye":210,"mouth":321,"cheek":402}},{"frame":819,"face":{"leye":105,"reye":205,"mouth":310,"cheek":403}},{"frame":823,"face":{"leye":110,"reye":210,"mouth":306,"cheek":403}},{"frame":824,"face":{"leye":107,"reye":207,"mouth":306,"cheek":403}},{"frame":828,"face":{"leye":107,"reye":207,"mouth":311,"cheek":403}},{"frame":833,"face":{"leye":107,"reye":207,"mouth":304,"cheek":403}},{"frame":855,"face":{"leye":107,"reye":207,"mouth":311,"cheek":403}},{"frame":874,"face":{"leye":107,"reye":207,"mouth":302,"cheek":403}},{"frame":880,"face":{"leye":102,"reye":206,"mouth":310,"cheek":403}},{"frame":905,"face":{"leye":110,"reye":210,"mouth":302,"cheek":403}},{"frame":909,"face":{"leye":106,"reye":206,"mouth":310,"cheek":403}},{"frame":936,"face":{"leye":102,"reye":202,"mouth":311,"cheek":403}},{"frame":951,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":957,"face":{"leye":119,"reye":219,"mouth":311,"cheek":403}},{"frame":968,"face":{"leye":102,"reye":202,"mouth":306,"cheek":403}},{"frame":968,"face":{"leye":102,"reye":202,"mouth":306,"cheek":403}}],"solo1":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":47,"face":{"leye":106,"reye":206,"mouth":328,"cheek":400}},{"frame":61,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":93,"face":{"leye":0,"reye":0,"mouth":304,"cheek":400}},{"frame":94,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":95,"face":{"leye":0,"reye":0,"mouth":304,"cheek":400}},{"frame":96,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":104,"face":{"leye":0,"reye":0,"mouth":0,"cheek":400}},{"frame":105,"face":{"leye":102,"reye":202,"mouth":310,"cheek":400}},{"frame":116,"face":{"leye":106,"reye":206,"mouth":327,"cheek":404}},{"frame":117,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":118,"face":{"leye":106,"reye":206,"mouth":327,"cheek":404}},{"frame":119,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":120,"face":{"leye":106,"reye":206,"mouth":327,"cheek":404}},{"frame":121,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":122,"face":{"leye":106,"reye":206,"mouth":327,"cheek":404}},{"frame":124,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":125,"face":{"leye":106,"reye":206,"mouth":327,"cheek":404}},{"frame":126,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":128,"face":{"leye":106,"reye":206,"mouth":327,"cheek":404}},{"frame":129,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":130,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":135,"face":{"leye":110,"reye":210,"mouth":310,"cheek":404}},{"frame":155,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":162,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":163,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":164,"face":{"leye":0,"reye":0,"mouth":321,"cheek":400}},{"frame":165,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":166,"face":{"leye":0,"reye":0,"mouth":312,"cheek":400}},{"frame":167,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":168,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":169,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":171,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":173,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":175,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":180,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":182,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":183,"face":{"leye":0,"reye":0,"mouth":302,"cheek":400}},{"frame":184,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":187,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":188,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":189,"face":{"leye":106,"reye":206,"mouth":327,"cheek":404}},{"frame":194,"face":{"leye":106,"reye":206,"mouth":304,"cheek":404}},{"frame":209,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":212,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":214,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":216,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":217,"face":{"leye":107,"reye":207,"mouth":321,"cheek":404}},{"frame":220,"face":{"leye":107,"reye":207,"mouth":302,"cheek":404}},{"frame":221,"face":{"leye":107,"reye":207,"mouth":311,"cheek":404}},{"frame":222,"face":{"leye":107,"reye":207,"mouth":321,"cheek":404}},{"frame":223,"face":{"leye":107,"reye":207,"mouth":323,"cheek":404}},{"frame":225,"face":{"leye":107,"reye":207,"mouth":321,"cheek":404}},{"frame":226,"face":{"leye":107,"reye":207,"mouth":311,"cheek":404}},{"frame":227,"face":{"leye":107,"reye":207,"mouth":321,"cheek":404}},{"frame":228,"face":{"leye":107,"reye":207,"mouth":302,"cheek":404}},{"frame":229,"face":{"leye":107,"reye":207,"mouth":323,"cheek":404}},{"frame":231,"face":{"leye":107,"reye":207,"mouth":302,"cheek":404}},{"frame":232,"face":{"leye":107,"reye":207,"mouth":311,"cheek":404}},{"frame":233,"face":{"leye":107,"reye":207,"mouth":0,"cheek":404}},{"frame":236,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":240,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":242,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":247,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":260,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":268,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":282,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":288,"face":{"leye":121,"reye":221,"mouth":321,"cheek":400}},{"frame":289,"face":{"leye":121,"reye":221,"mouth":311,"cheek":402}},{"frame":293,"face":{"leye":121,"reye":221,"mouth":323,"cheek":402}},{"frame":295,"face":{"leye":121,"reye":221,"mouth":311,"cheek":402}},{"frame":297,"face":{"leye":121,"reye":221,"mouth":321,"cheek":402}},{"frame":298,"face":{"leye":121,"reye":221,"mouth":323,"cheek":402}},{"frame":300,"face":{"leye":121,"reye":221,"mouth":312,"cheek":402}},{"frame":304,"face":{"leye":119,"reye":220,"mouth":321,"cheek":400}},{"frame":306,"face":{"leye":119,"reye":220,"mouth":312,"cheek":400}},{"frame":307,"face":{"leye":119,"reye":220,"mouth":311,"cheek":400}},{"frame":309,"face":{"leye":119,"reye":220,"mouth":321,"cheek":400}},{"frame":310,"face":{"leye":119,"reye":220,"mouth":311,"cheek":400}},{"frame":312,"face":{"leye":119,"reye":220,"mouth":319,"cheek":400}},{"frame":315,"face":{"leye":119,"reye":220,"mouth":321,"cheek":400}},{"frame":319,"face":{"leye":106,"reye":206,"mouth":319,"cheek":404}},{"frame":320,"face":{"leye":116,"reye":216,"mouth":319,"cheek":402}},{"frame":321,"face":{"leye":110,"reye":210,"mouth":323,"cheek":404}},{"frame":323,"face":{"leye":106,"reye":206,"mouth":312,"cheek":404}},{"frame":325,"face":{"leye":116,"reye":216,"mouth":312,"cheek":402}},{"frame":326,"face":{"leye":110,"reye":210,"mouth":312,"cheek":404}},{"frame":327,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":329,"face":{"leye":102,"reye":202,"mouth":302,"cheek":400}},{"frame":331,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":333,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":335,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":337,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":339,"face":{"leye":0,"reye":0,"mouth":312,"cheek":400}},{"frame":340,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":346,"face":{"leye":106,"reye":206,"mouth":302,"cheek":400}},{"frame":348,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":351,"face":{"leye":106,"reye":206,"mouth":319,"cheek":400}},{"frame":354,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":356,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":357,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":359,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":361,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":362,"face":{"leye":106,"reye":206,"mouth":321,"cheek":402}},{"frame":363,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":364,"face":{"leye":106,"reye":206,"mouth":321,"cheek":402}},{"frame":366,"face":{"leye":106,"reye":206,"mouth":312,"cheek":402}},{"frame":368,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":370,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":372,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":373,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":390,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":391,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":398,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":404,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":407,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":411,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":415,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":417,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":418,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":426,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":433,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":442,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":443,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":444,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":447,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":450,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":452,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":456,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":460,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":465,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":468,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":473,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":475,"face":{"leye":106,"reye":201,"mouth":321,"cheek":402}},{"frame":478,"face":{"leye":106,"reye":201,"mouth":311,"cheek":402}},{"frame":480,"face":{"leye":106,"reye":201,"mouth":323,"cheek":402}},{"frame":481,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":482,"face":{"leye":101,"reye":206,"mouth":323,"cheek":402}},{"frame":485,"face":{"leye":101,"reye":206,"mouth":311,"cheek":402}},{"frame":487,"face":{"leye":101,"reye":206,"mouth":312,"cheek":402}},{"frame":488,"face":{"leye":101,"reye":206,"mouth":312,"cheek":400}},{"frame":493,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":495,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":498,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":499,"face":{"leye":0,"reye":0,"mouth":311,"cheek":400}},{"frame":500,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":501,"face":{"leye":0,"reye":0,"mouth":311,"cheek":400}},{"frame":502,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":504,"face":{"leye":119,"reye":220,"mouth":328,"cheek":400}},{"frame":518,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":524,"face":{"leye":110,"reye":210,"mouth":302,"cheek":404}},{"frame":532,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":533,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":538,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":541,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}},{"frame":543,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":549,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":555,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":556,"face":{"leye":110,"reye":210,"mouth":321,"cheek":404}},{"frame":558,"face":{"leye":110,"reye":210,"mouth":312,"cheek":404}},{"frame":559,"face":{"leye":110,"reye":210,"mouth":304,"cheek":404}},{"frame":561,"face":{"leye":110,"reye":210,"mouth":312,"cheek":404}},{"frame":562,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":566,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":571,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":573,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":574,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":580,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":583,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":584,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":585,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":586,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":587,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":588,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":589,"face":{"leye":0,"reye":0,"mouth":0,"cheek":400}},{"frame":590,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":600,"face":{"leye":106,"reye":206,"mouth":302,"cheek":404}},{"frame":602,"face":{"leye":106,"reye":206,"mouth":327,"cheek":404}},{"frame":608,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":611,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":616,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":619,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":622,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":627,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":629,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":636,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":638,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":639,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":642,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":645,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":647,"face":{"leye":0,"reye":0,"mouth":319,"cheek":400}},{"frame":648,"face":{"leye":106,"reye":201,"mouth":319,"cheek":402}},{"frame":655,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":676,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":678,"face":{"leye":106,"reye":206,"mouth":319,"cheek":404}},{"frame":679,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":681,"face":{"leye":106,"reye":206,"mouth":319,"cheek":404}},{"frame":685,"face":{"leye":106,"reye":206,"mouth":302,"cheek":404}},{"frame":691,"face":{"leye":106,"reye":206,"mouth":312,"cheek":404}},{"frame":692,"face":{"leye":106,"reye":206,"mouth":302,"cheek":404}},{"frame":693,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":698,"face":{"leye":106,"reye":206,"mouth":302,"cheek":404}},{"frame":705,"face":{"leye":106,"reye":206,"mouth":319,"cheek":404}},{"frame":706,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":708,"face":{"leye":106,"reye":206,"mouth":319,"cheek":404}},{"frame":709,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":716,"face":{"leye":106,"reye":206,"mouth":302,"cheek":404}},{"frame":719,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":724,"face":{"leye":106,"reye":206,"mouth":319,"cheek":404}},{"frame":731,"face":{"leye":106,"reye":206,"mouth":302,"cheek":404}},{"frame":733,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":742,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":747,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":749,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":751,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":755,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":756,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":761,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":763,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":765,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":767,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":770,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":773,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":776,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":778,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":779,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":781,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":785,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":790,"face":{"leye":121,"reye":221,"mouth":321,"cheek":402}},{"frame":792,"face":{"leye":121,"reye":221,"mouth":311,"cheek":402}},{"frame":794,"face":{"leye":121,"reye":221,"mouth":321,"cheek":402}},{"frame":795,"face":{"leye":121,"reye":221,"mouth":311,"cheek":402}},{"frame":799,"face":{"leye":121,"reye":221,"mouth":304,"cheek":402}},{"frame":804,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":810,"face":{"leye":106,"reye":206,"mouth":319,"cheek":404}},{"frame":813,"face":{"leye":106,"reye":206,"mouth":304,"cheek":404}},{"frame":819,"face":{"leye":110,"reye":210,"mouth":311,"cheek":404}},{"frame":820,"face":{"leye":110,"reye":210,"mouth":312,"cheek":404}},{"frame":822,"face":{"leye":110,"reye":210,"mouth":319,"cheek":404}},{"frame":823,"face":{"leye":110,"reye":210,"mouth":323,"cheek":404}},{"frame":827,"face":{"leye":110,"reye":210,"mouth":321,"cheek":404}},{"frame":829,"face":{"leye":110,"reye":210,"mouth":323,"cheek":404}},{"frame":831,"face":{"leye":110,"reye":210,"mouth":304,"cheek":404}},{"frame":833,"face":{"leye":110,"reye":210,"mouth":311,"cheek":404}},{"frame":835,"face":{"leye":110,"reye":210,"mouth":304,"cheek":404}},{"frame":836,"face":{"leye":110,"reye":210,"mouth":323,"cheek":404}},{"frame":838,"face":{"leye":110,"reye":210,"mouth":319,"cheek":404}},{"frame":841,"face":{"leye":110,"reye":210,"mouth":304,"cheek":404}},{"frame":845,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":846,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":847,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":852,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":856,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":857,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":859,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":861,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":862,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":863,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":864,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":869,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":873,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":879,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":882,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":884,"face":{"leye":110,"reye":210,"mouth":311,"cheek":404}},{"frame":886,"face":{"leye":110,"reye":210,"mouth":321,"cheek":404}},{"frame":888,"face":{"leye":110,"reye":210,"mouth":312,"cheek":404}},{"frame":889,"face":{"leye":110,"reye":210,"mouth":302,"cheek":404}},{"frame":890,"face":{"leye":110,"reye":210,"mouth":321,"cheek":404}},{"frame":891,"face":{"leye":110,"reye":210,"mouth":311,"cheek":404}},{"frame":893,"face":{"leye":110,"reye":210,"mouth":323,"cheek":404}},{"frame":895,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":897,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":901,"face":{"leye":101,"reye":206,"mouth":310,"cheek":402}}],"solo2":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":27,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":35,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":42,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":51,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":66,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":71,"face":{"leye":106,"reye":206,"mouth":310,"cheek":402}},{"frame":96,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":104,"face":{"leye":121,"reye":221,"mouth":302,"cheek":402}},{"frame":119,"face":{"leye":121,"reye":221,"mouth":311,"cheek":402}},{"frame":128,"face":{"leye":106,"reye":206,"mouth":302,"cheek":400}},{"frame":134,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":136,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":138,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":140,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":142,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":143,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":145,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":148,"face":{"leye":105,"reye":205,"mouth":313,"cheek":400}},{"frame":149,"face":{"leye":105,"reye":205,"mouth":311,"cheek":400}},{"frame":151,"face":{"leye":105,"reye":205,"mouth":317,"cheek":400}},{"frame":153,"face":{"leye":105,"reye":205,"mouth":312,"cheek":400}},{"frame":155,"face":{"leye":105,"reye":205,"mouth":319,"cheek":400}},{"frame":157,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":161,"face":{"leye":106,"reye":206,"mouth":321,"cheek":403}},{"frame":163,"face":{"leye":106,"reye":206,"mouth":310,"cheek":403}},{"frame":166,"face":{"leye":110,"reye":210,"mouth":319,"cheek":403}},{"frame":169,"face":{"leye":110,"reye":210,"mouth":304,"cheek":403}},{"frame":171,"face":{"leye":110,"reye":210,"mouth":312,"cheek":403}},{"frame":173,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":174,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":177,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":179,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":181,"face":{"leye":107,"reye":207,"mouth":317,"cheek":400}},{"frame":183,"face":{"leye":107,"reye":207,"mouth":312,"cheek":400}},{"frame":185,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":188,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":191,"face":{"leye":102,"reye":206,"mouth":321,"cheek":400}},{"frame":193,"face":{"leye":102,"reye":206,"mouth":310,"cheek":400}},{"frame":196,"face":{"leye":102,"reye":206,"mouth":321,"cheek":400}},{"frame":202,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":205,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":207,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":209,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":217,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":221,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":224,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":227,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":229,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":232,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":237,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":240,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":244,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":248,"face":{"leye":107,"reye":207,"mouth":310,"cheek":403}},{"frame":252,"face":{"leye":107,"reye":207,"mouth":321,"cheek":403}},{"frame":254,"face":{"leye":107,"reye":207,"mouth":310,"cheek":403}},{"frame":257,"face":{"leye":107,"reye":207,"mouth":321,"cheek":403}},{"frame":259,"face":{"leye":107,"reye":207,"mouth":311,"cheek":403}},{"frame":262,"face":{"leye":107,"reye":207,"mouth":321,"cheek":403}},{"frame":265,"face":{"leye":119,"reye":219,"mouth":310,"cheek":402}},{"frame":267,"face":{"leye":119,"reye":219,"mouth":321,"cheek":402}},{"frame":270,"face":{"leye":119,"reye":219,"mouth":310,"cheek":402}},{"frame":273,"face":{"leye":119,"reye":219,"mouth":321,"cheek":402}},{"frame":276,"face":{"leye":119,"reye":219,"mouth":311,"cheek":402}},{"frame":278,"face":{"leye":119,"reye":219,"mouth":321,"cheek":402}},{"frame":281,"face":{"leye":119,"reye":219,"mouth":304,"cheek":402}},{"frame":284,"face":{"leye":105,"reye":205,"mouth":317,"cheek":402}},{"frame":287,"face":{"leye":105,"reye":205,"mouth":312,"cheek":402}},{"frame":289,"face":{"leye":105,"reye":205,"mouth":321,"cheek":402}},{"frame":293,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":312,"face":{"leye":106,"reye":201,"mouth":321,"cheek":402}},{"frame":313,"face":{"leye":106,"reye":201,"mouth":310,"cheek":402}},{"frame":318,"face":{"leye":107,"reye":207,"mouth":304,"cheek":402}},{"frame":334,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":351,"face":{"leye":101,"reye":201,"mouth":306,"cheek":400}},{"frame":367,"face":{"leye":116,"reye":216,"mouth":302,"cheek":402}},{"frame":391,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":400,"face":{"leye":119,"reye":219,"mouth":311,"cheek":400}},{"frame":403,"face":{"leye":119,"reye":219,"mouth":321,"cheek":400}},{"frame":404,"face":{"leye":119,"reye":219,"mouth":311,"cheek":400}},{"frame":405,"face":{"leye":119,"reye":219,"mouth":321,"cheek":400}},{"frame":408,"face":{"leye":119,"reye":219,"mouth":311,"cheek":400}},{"frame":410,"face":{"leye":119,"reye":219,"mouth":321,"cheek":400}},{"frame":414,"face":{"leye":119,"reye":219,"mouth":311,"cheek":400}},{"frame":421,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":424,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":427,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":429,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":431,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":436,"face":{"leye":117,"reye":217,"mouth":302,"cheek":400}},{"frame":438,"face":{"leye":119,"reye":220,"mouth":321,"cheek":400}},{"frame":440,"face":{"leye":119,"reye":220,"mouth":319,"cheek":400}},{"frame":441,"face":{"leye":119,"reye":220,"mouth":312,"cheek":400}},{"frame":447,"face":{"leye":108,"reye":209,"mouth":319,"cheek":400}},{"frame":448,"face":{"leye":108,"reye":209,"mouth":311,"cheek":400}},{"frame":447,"face":{"leye":108,"reye":209,"mouth":319,"cheek":400}},{"frame":455,"face":{"leye":108,"reye":209,"mouth":311,"cheek":400}},{"frame":457,"face":{"leye":108,"reye":209,"mouth":312,"cheek":400}},{"frame":458,"face":{"leye":108,"reye":209,"mouth":302,"cheek":400}},{"frame":460,"face":{"leye":108,"reye":209,"mouth":314,"cheek":400}},{"frame":463,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":465,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":467,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":469,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":472,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":474,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":480,"face":{"leye":105,"reye":205,"mouth":312,"cheek":400}},{"frame":481,"face":{"leye":105,"reye":205,"mouth":323,"cheek":400}},{"frame":484,"face":{"leye":105,"reye":205,"mouth":319,"cheek":400}},{"frame":486,"face":{"leye":105,"reye":205,"mouth":312,"cheek":400}},{"frame":488,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":492,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":494,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":497,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":498,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":501,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":506,"face":{"leye":102,"reye":206,"mouth":321,"cheek":400}},{"frame":512,"face":{"leye":102,"reye":206,"mouth":317,"cheek":400}},{"frame":521,"face":{"leye":102,"reye":206,"mouth":317,"cheek":400}},{"frame":527,"face":{"leye":102,"reye":206,"mouth":302,"cheek":400}},{"frame":533,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":536,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":536,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":542,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":544,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":546,"face":{"leye":107,"reye":207,"mouth":311,"cheek":402}},{"frame":548,"face":{"leye":107,"reye":207,"mouth":321,"cheek":402}},{"frame":549,"face":{"leye":107,"reye":207,"mouth":312,"cheek":402}},{"frame":553,"face":{"leye":107,"reye":207,"mouth":319,"cheek":402}},{"frame":559,"face":{"leye":106,"reye":202,"mouth":311,"cheek":400}},{"frame":562,"face":{"leye":106,"reye":202,"mouth":321,"cheek":400}},{"frame":565,"face":{"leye":106,"reye":202,"mouth":319,"cheek":400}},{"frame":566,"face":{"leye":106,"reye":202,"mouth":311,"cheek":400}},{"frame":569,"face":{"leye":106,"reye":202,"mouth":321,"cheek":400}},{"frame":571,"face":{"leye":106,"reye":202,"mouth":319,"cheek":400}},{"frame":573,"face":{"leye":107,"reye":207,"mouth":312,"cheek":403}},{"frame":575,"face":{"leye":107,"reye":207,"mouth":319,"cheek":403}},{"frame":577,"face":{"leye":107,"reye":207,"mouth":321,"cheek":403}},{"frame":579,"face":{"leye":107,"reye":207,"mouth":323,"cheek":403}},{"frame":582,"face":{"leye":107,"reye":207,"mouth":312,"cheek":403}},{"frame":586,"face":{"leye":107,"reye":207,"mouth":304,"cheek":403}},{"frame":595,"face":{"leye":102,"reye":202,"mouth":323,"cheek":400}},{"frame":599,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":601,"face":{"leye":102,"reye":202,"mouth":323,"cheek":400}},{"frame":603,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":611,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":614,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":617,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":620,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":625,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":628,"face":{"leye":101,"reye":201,"mouth":323,"cheek":402}},{"frame":630,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":634,"face":{"leye":101,"reye":201,"mouth":321,"cheek":402}},{"frame":637,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":640,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":643,"face":{"leye":106,"reye":206,"mouth":302,"cheek":403}},{"frame":649,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":663,"face":{"leye":105,"reye":205,"mouth":305,"cheek":400}},{"frame":678,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":679,"face":{"leye":102,"reye":202,"mouth":317,"cheek":400}},{"frame":681,"face":{"leye":107,"reye":207,"mouth":321,"cheek":400}},{"frame":683,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":685,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":687,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":689,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":692,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":696,"face":{"leye":119,"reye":219,"mouth":312,"cheek":400}},{"frame":699,"face":{"leye":119,"reye":219,"mouth":321,"cheek":400}},{"frame":700,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":701,"face":{"leye":106,"reye":206,"mouth":319,"cheek":400}},{"frame":702,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":705,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":707,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":709,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":710,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":713,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":714,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":716,"face":{"leye":119,"reye":219,"mouth":317,"cheek":400}},{"frame":718,"face":{"leye":119,"reye":219,"mouth":311,"cheek":400}},{"frame":721,"face":{"leye":119,"reye":219,"mouth":304,"cheek":400}},{"frame":723,"face":{"leye":119,"reye":219,"mouth":312,"cheek":400}},{"frame":724,"face":{"leye":107,"reye":207,"mouth":317,"cheek":400}},{"frame":727,"face":{"leye":107,"reye":207,"mouth":319,"cheek":400}},{"frame":727,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":729,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":730,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":731,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":735,"face":{"leye":102,"reye":206,"mouth":323,"cheek":402}},{"frame":737,"face":{"leye":102,"reye":206,"mouth":310,"cheek":402}},{"frame":740,"face":{"leye":102,"reye":206,"mouth":323,"cheek":402}},{"frame":745,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":751,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":754,"face":{"leye":110,"reye":210,"mouth":317,"cheek":400}},{"frame":764,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":766,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":769,"face":{"leye":102,"reye":202,"mouth":317,"cheek":400}},{"frame":771,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":773,"face":{"leye":102,"reye":202,"mouth":323,"cheek":400}},{"frame":776,"face":{"leye":102,"reye":206,"mouth":321,"cheek":400}},{"frame":783,"face":{"leye":102,"reye":206,"mouth":319,"cheek":400}},{"frame":784,"face":{"leye":102,"reye":206,"mouth":311,"cheek":400}},{"frame":787,"face":{"leye":102,"reye":206,"mouth":319,"cheek":400}},{"frame":790,"face":{"leye":102,"reye":206,"mouth":316,"cheek":400}},{"frame":793,"face":{"leye":107,"reye":207,"mouth":310,"cheek":403}},{"frame":795,"face":{"leye":107,"reye":207,"mouth":323,"cheek":403}},{"frame":798,"face":{"leye":107,"reye":207,"mouth":310,"cheek":403}},{"frame":800,"face":{"leye":107,"reye":207,"mouth":323,"cheek":403}},{"frame":803,"face":{"leye":107,"reye":207,"mouth":311,"cheek":403}},{"frame":806,"face":{"leye":107,"reye":207,"mouth":321,"cheek":403}},{"frame":809,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":812,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":814,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":814,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":817,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":819,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":821,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":824,"face":{"leye":105,"reye":205,"mouth":311,"cheek":402}},{"frame":826,"face":{"leye":105,"reye":205,"mouth":317,"cheek":402}},{"frame":828,"face":{"leye":105,"reye":205,"mouth":312,"cheek":402}},{"frame":830,"face":{"leye":105,"reye":205,"mouth":319,"cheek":402}},{"frame":832,"face":{"leye":105,"reye":205,"mouth":311,"cheek":402}},{"frame":836,"face":{"leye":105,"reye":205,"mouth":321,"cheek":402}},{"frame":839,"face":{"leye":105,"reye":205,"mouth":310,"cheek":402}},{"frame":842,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":845,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":847,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":848,"face":{"leye":110,"reye":210,"mouth":317,"cheek":400}},{"frame":850,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":853,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":855,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":856,"face":{"leye":110,"reye":210,"mouth":317,"cheek":400}},{"frame":859,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":860,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":861,"face":{"leye":101,"reye":206,"mouth":319,"cheek":400}},{"frame":863,"face":{"leye":101,"reye":206,"mouth":316,"cheek":400}},{"frame":866,"face":{"leye":101,"reye":206,"mouth":323,"cheek":400}},{"frame":867,"face":{"leye":107,"reye":207,"mouth":323,"cheek":402}},{"frame":869,"face":{"leye":107,"reye":207,"mouth":310,"cheek":402}},{"frame":872,"face":{"leye":107,"reye":207,"mouth":323,"cheek":402}},{"frame":877,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":881,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":883,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":885,"face":{"leye":102,"reye":202,"mouth":317,"cheek":400}},{"frame":893,"face":{"leye":116,"reye":216,"mouth":321,"cheek":402}},{"frame":897,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":900,"face":{"leye":116,"reye":216,"mouth":321,"cheek":402}},{"frame":902,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":905,"face":{"leye":116,"reye":216,"mouth":321,"cheek":402}},{"frame":910,"face":{"leye":110,"reye":210,"mouth":321,"cheek":402}},{"frame":914,"face":{"leye":110,"reye":210,"mouth":0,"cheek":402}},{"frame":916,"face":{"leye":110,"reye":210,"mouth":323,"cheek":402}},{"frame":920,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":921,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":924,"face":{"leye":107,"reye":207,"mouth":310,"cheek":403}},{"frame":927,"face":{"leye":107,"reye":207,"mouth":323,"cheek":403}},{"frame":930,"face":{"leye":107,"reye":207,"mouth":310,"cheek":403}},{"frame":932,"face":{"leye":107,"reye":207,"mouth":323,"cheek":403}},{"frame":935,"face":{"leye":107,"reye":207,"mouth":311,"cheek":403}},{"frame":937,"face":{"leye":107,"reye":207,"mouth":321,"cheek":403}},{"frame":940,"face":{"leye":106,"reye":202,"mouth":310,"cheek":403}},{"frame":943,"face":{"leye":106,"reye":202,"mouth":323,"cheek":403}},{"frame":946,"face":{"leye":106,"reye":202,"mouth":310,"cheek":403}},{"frame":948,"face":{"leye":106,"reye":202,"mouth":323,"cheek":403}},{"frame":951,"face":{"leye":106,"reye":202,"mouth":311,"cheek":403}},{"frame":954,"face":{"leye":106,"reye":202,"mouth":321,"cheek":403}},{"frame":957,"face":{"leye":106,"reye":202,"mouth":306,"cheek":403}},{"frame":959,"face":{"leye":110,"reye":210,"mouth":306,"cheek":403}},{"frame":960,"face":{"leye":110,"reye":210,"mouth":317,"cheek":403}},{"frame":963,"face":{"leye":110,"reye":210,"mouth":312,"cheek":403}},{"frame":965,"face":{"leye":110,"reye":210,"mouth":323,"cheek":403}},{"frame":969,"face":{"leye":105,"reye":205,"mouth":317,"cheek":403}},{"frame":987,"face":{"leye":101,"reye":206,"mouth":321,"cheek":402}},{"frame":989,"face":{"leye":101,"reye":206,"mouth":310,"cheek":402}},{"frame":990,"face":{"leye":101,"reye":206,"mouth":321,"cheek":402}},{"frame":993,"face":{"leye":101,"reye":206,"mouth":304,"cheek":402}},{"frame":1010,"face":{"leye":101,"reye":201,"mouth":310,"cheek":402}},{"frame":1026,"face":{"leye":101,"reye":201,"mouth":305,"cheek":402}},{"frame":1042,"face":{"leye":119,"reye":219,"mouth":311,"cheek":402}},{"frame":1058,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":1071,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":1076,"face":{"leye":106,"reye":202,"mouth":310,"cheek":400}},{"frame":1120,"face":{"leye":106,"reye":202,"mouth":302,"cheek":400}}],"solo3":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":6,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":36,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":41,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":51,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":56,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":59,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":60,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":61,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":63,"face":{"leye":122,"reye":222,"mouth":304,"cheek":400}},{"frame":67,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":74,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":77,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":82,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":87,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":91,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":95,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":100,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":103,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":108,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":111,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":115,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":121,"face":{"leye":107,"reye":207,"mouth":304,"cheek":404}},{"frame":129,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":137,"face":{"leye":107,"reye":207,"mouth":321,"cheek":404}},{"frame":140,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":144,"face":{"leye":107,"reye":207,"mouth":321,"cheek":404}},{"frame":145,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":147,"face":{"leye":107,"reye":207,"mouth":321,"cheek":404}},{"frame":150,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":153,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":156,"face":{"leye":110,"reye":210,"mouth":0,"cheek":400}},{"frame":157,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":158,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":160,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":161,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":163,"face":{"leye":107,"reye":207,"mouth":321,"cheek":404}},{"frame":165,"face":{"leye":107,"reye":207,"mouth":0,"cheek":404}},{"frame":166,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":168,"face":{"leye":107,"reye":207,"mouth":311,"cheek":404}},{"frame":170,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":173,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":177,"face":{"leye":102,"reye":202,"mouth":0,"cheek":400}},{"frame":179,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":182,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":186,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":189,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":199,"face":{"leye":101,"reye":206,"mouth":311,"cheek":402}},{"frame":202,"face":{"leye":101,"reye":206,"mouth":312,"cheek":402}},{"frame":204,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":212,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":214,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":216,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":218,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":221,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":223,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":229,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":234,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":236,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":242,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":245,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":247,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":251,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":254,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":257,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":260,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":263,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":266,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":268,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":270,"face":{"leye":101,"reye":206,"mouth":321,"cheek":402}},{"frame":272,"face":{"leye":101,"reye":206,"mouth":311,"cheek":402}},{"frame":276,"face":{"leye":101,"reye":206,"mouth":304,"cheek":402}},{"frame":280,"face":{"leye":122,"reye":222,"mouth":312,"cheek":400}},{"frame":284,"face":{"leye":122,"reye":222,"mouth":319,"cheek":400}},{"frame":286,"face":{"leye":122,"reye":222,"mouth":0,"cheek":400}},{"frame":287,"face":{"leye":122,"reye":222,"mouth":319,"cheek":400}},{"frame":289,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":291,"face":{"leye":106,"reye":206,"mouth":312,"cheek":400}},{"frame":295,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":298,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":300,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":302,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":304,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":307,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":309,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":311,"face":{"leye":106,"reye":206,"mouth":304,"cheek":404}},{"frame":313,"face":{"leye":106,"reye":206,"mouth":319,"cheek":404}},{"frame":314,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":317,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":321,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":324,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":325,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":328,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":330,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":332,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":334,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":342,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":345,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":351,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":353,"face":{"leye":106,"reye":206,"mouth":0,"cheek":402}},{"frame":354,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":357,"face":{"leye":106,"reye":206,"mouth":319,"cheek":402}},{"frame":359,"face":{"leye":106,"reye":206,"mouth":321,"cheek":402}},{"frame":364,"face":{"leye":106,"reye":206,"mouth":312,"cheek":402}},{"frame":368,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":371,"face":{"leye":106,"reye":206,"mouth":321,"cheek":402}},{"frame":373,"face":{"leye":106,"reye":206,"mouth":319,"cheek":402}},{"frame":375,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":377,"face":{"leye":106,"reye":206,"mouth":321,"cheek":402}},{"frame":379,"face":{"leye":106,"reye":206,"mouth":0,"cheek":402}},{"frame":380,"face":{"leye":106,"reye":206,"mouth":321,"cheek":402}},{"frame":383,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":386,"face":{"leye":122,"reye":222,"mouth":321,"cheek":400}},{"frame":391,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":395,"face":{"leye":116,"reye":216,"mouth":321,"cheek":402}},{"frame":399,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":403,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":404,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":406,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":408,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":410,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":413,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":414,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":418,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":421,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":424,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":427,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":431,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":434,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":437,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":445,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":447,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":449,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":454,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":456,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":464,"face":{"leye":106,"reye":206,"mouth":312,"cheek":402}},{"frame":467,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":474,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":475,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":476,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":482,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":486,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":489,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":493,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":403,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":499,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":499,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":506,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":506,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":508,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":511,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":517,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":524,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":528,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":530,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":532,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":534,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":537,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":541,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":544,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":545,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":551,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":555,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":557,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":559,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":563,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":567,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":581,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":583,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":587,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":589,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":590,"face":{"leye":106,"reye":206,"mouth":319,"cheek":400}},{"frame":592,"face":{"leye":106,"reye":206,"mouth":312,"cheek":400}},{"frame":595,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":598,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":602,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":605,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":610,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":612,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":614,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":615,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":625,"face":{"leye":101,"reye":206,"mouth":311,"cheek":402}},{"frame":626,"face":{"leye":101,"reye":206,"mouth":312,"cheek":402}},{"frame":629,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":637,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":639,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":643,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":644,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":650,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":652,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":655,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":658,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":659,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":661,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":663,"face":{"leye":106,"reye":206,"mouth":319,"cheek":400}},{"frame":665,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":667,"face":{"leye":106,"reye":206,"mouth":319,"cheek":400}},{"frame":668,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":670,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":674,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":676,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":678,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":681,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":683,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":684,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":690,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":696,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":701,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":703,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":705,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":706,"face":{"leye":110,"reye":210,"mouth":0,"cheek":400}},{"frame":708,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":709,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":710,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":714,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":719,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":725,"face":{"leye":106,"reye":206,"mouth":312,"cheek":404}},{"frame":730,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":732,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":734,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":736,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":739,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":741,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":747,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":749,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":750,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":752,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":756,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":759,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":761,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":763,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":765,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":769,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":771,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":776,"face":{"leye":106,"reye":206,"mouth":312,"cheek":400}},{"frame":778,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":780,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":782,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":784,"face":{"leye":106,"reye":206,"mouth":0,"cheek":400}},{"frame":785,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":789,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":792,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":796,"face":{"leye":106,"reye":206,"mouth":312,"cheek":400}},{"frame":800,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":803,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":807,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":811,"face":{"leye":106,"reye":206,"mouth":319,"cheek":400}},{"frame":814,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":816,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":817,"face":{"leye":106,"reye":206,"mouth":0,"cheek":400}},{"frame":819,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":820,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":823,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":825,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":827,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":829,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":830,"face":{"leye":106,"reye":206,"mouth":0,"cheek":400}},{"frame":831,"face":{"leye":106,"reye":206,"mouth":312,"cheek":400}},{"frame":834,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":836,"face":{"leye":106,"reye":206,"mouth":312,"cheek":400}},{"frame":838,"face":{"leye":106,"reye":201,"mouth":312,"cheek":402}},{"frame":841,"face":{"leye":106,"reye":201,"mouth":0,"cheek":402}},{"frame":843,"face":{"leye":106,"reye":201,"mouth":312,"cheek":402}},{"frame":845,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":847,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":853,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":854,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":857,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":860,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":863,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":866,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":873,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":875,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":876,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":877,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":880,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":884,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":889,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":897,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":900,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":902,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":908,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":911,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":913,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":916,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":918,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":926,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":927,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":931,"face":{"leye":106,"reye":206,"mouth":319,"cheek":400}},{"frame":933,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":936,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":937,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":941,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":942,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":944,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":946,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":948,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":953,"face":{"leye":106,"reye":201,"mouth":312,"cheek":402}},{"frame":968,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":1010,"face":{"leye":107,"reye":207,"mouth":304,"cheek":404}},{"frame":1027,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":1039,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}}],"solo4":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":9,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":50,"face":{"leye":0,"reye":0,"mouth":304,"cheek":400}},{"frame":53,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":75,"face":{"leye":0,"reye":0,"mouth":304,"cheek":400}},{"frame":77,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":81,"face":{"leye":0,"reye":0,"mouth":304,"cheek":400}},{"frame":82,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":97,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":119,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":177,"face":{"leye":0,"reye":0,"mouth":302,"cheek":402}},{"frame":181,"face":{"leye":101,"reye":201,"mouth":302,"cheek":402}},{"frame":187,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":190,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":201,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":204,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":206,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":214,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":228,"face":{"leye":111,"reye":211,"mouth":304,"cheek":400}},{"frame":231,"face":{"leye":111,"reye":211,"mouth":312,"cheek":400}},{"frame":236,"face":{"leye":111,"reye":211,"mouth":323,"cheek":400}},{"frame":238,"face":{"leye":111,"reye":211,"mouth":319,"cheek":400}},{"frame":241,"face":{"leye":111,"reye":211,"mouth":323,"cheek":400}},{"frame":245,"face":{"leye":111,"reye":211,"mouth":311,"cheek":400}},{"frame":248,"face":{"leye":111,"reye":211,"mouth":319,"cheek":400}},{"frame":250,"face":{"leye":111,"reye":211,"mouth":323,"cheek":400}},{"frame":258,"face":{"leye":111,"reye":211,"mouth":319,"cheek":400}},{"frame":275,"face":{"leye":119,"reye":219,"mouth":311,"cheek":400}},{"frame":278,"face":{"leye":119,"reye":219,"mouth":321,"cheek":400}},{"frame":280,"face":{"leye":119,"reye":219,"mouth":311,"cheek":400}},{"frame":280,"face":{"leye":119,"reye":219,"mouth":317,"cheek":400}},{"frame":285,"face":{"leye":119,"reye":219,"mouth":312,"cheek":400}},{"frame":288,"face":{"leye":119,"reye":219,"mouth":323,"cheek":400}},{"frame":291,"face":{"leye":119,"reye":219,"mouth":311,"cheek":400}},{"frame":299,"face":{"leye":119,"reye":219,"mouth":304,"cheek":400}},{"frame":301,"face":{"leye":119,"reye":219,"mouth":323,"cheek":400}},{"frame":312,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":318,"face":{"leye":117,"reye":217,"mouth":323,"cheek":400}},{"frame":321,"face":{"leye":117,"reye":217,"mouth":312,"cheek":400}},{"frame":324,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":326,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":334,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":338,"face":{"leye":117,"reye":217,"mouth":323,"cheek":400}},{"frame":346,"face":{"leye":117,"reye":217,"mouth":312,"cheek":400}},{"frame":351,"face":{"leye":0,"reye":0,"mouth":312,"cheek":400}},{"frame":354,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":359,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":362,"face":{"leye":101,"reye":211,"mouth":323,"cheek":400}},{"frame":364,"face":{"leye":101,"reye":211,"mouth":319,"cheek":400}},{"frame":368,"face":{"leye":101,"reye":211,"mouth":321,"cheek":400}},{"frame":370,"face":{"leye":101,"reye":211,"mouth":312,"cheek":400}},{"frame":373,"face":{"leye":101,"reye":211,"mouth":323,"cheek":400}},{"frame":378,"face":{"leye":101,"reye":211,"mouth":321,"cheek":400}},{"frame":385,"face":{"leye":101,"reye":211,"mouth":311,"cheek":400}},{"frame":387,"face":{"leye":101,"reye":211,"mouth":311,"cheek":400}},{"frame":389,"face":{"leye":101,"reye":211,"mouth":323,"cheek":400}},{"frame":396,"face":{"leye":111,"reye":211,"mouth":302,"cheek":400}},{"frame":400,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":403,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":408,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":414,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":420,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":422,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":433,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":438,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}},{"frame":441,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":445,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":451,"face":{"leye":110,"reye":210,"mouth":0,"cheek":400}},{"frame":453,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":455,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":458,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":463,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":466,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":471,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":476,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":478,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":484,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":486,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":488,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":493,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":498,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":504,"face":{"leye":119,"reye":219,"mouth":321,"cheek":400}},{"frame":507,"face":{"leye":119,"reye":219,"mouth":323,"cheek":400}},{"frame":510,"face":{"leye":119,"reye":219,"mouth":311,"cheek":400}},{"frame":531,"face":{"leye":119,"reye":219,"mouth":0,"cheek":400}},{"frame":532,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":533,"face":{"leye":117,"reye":217,"mouth":319,"cheek":400}},{"frame":535,"face":{"leye":117,"reye":217,"mouth":323,"cheek":400}},{"frame":539,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":542,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":547,"face":{"leye":117,"reye":217,"mouth":317,"cheek":400}},{"frame":554,"face":{"leye":119,"reye":220,"mouth":317,"cheek":400}},{"frame":557,"face":{"leye":119,"reye":220,"mouth":321,"cheek":400}},{"frame":562,"face":{"leye":119,"reye":220,"mouth":311,"cheek":400}},{"frame":564,"face":{"leye":119,"reye":220,"mouth":321,"cheek":400}},{"frame":565,"face":{"leye":108,"reye":209,"mouth":321,"cheek":400}},{"frame":566,"face":{"leye":108,"reye":209,"mouth":311,"cheek":400}},{"frame":570,"face":{"leye":108,"reye":209,"mouth":321,"cheek":400}},{"frame":575,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":577,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":582,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":583,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":585,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":586,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":594,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":597,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":601,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":605,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":608,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":614,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":618,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":625,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":627,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":630,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":633,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":638,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":641,"face":{"leye":106,"reye":206,"mouth":316,"cheek":400}},{"frame":647,"face":{"leye":106,"reye":206,"mouth":317,"cheek":400}},{"frame":652,"face":{"leye":106,"reye":206,"mouth":319,"cheek":400}},{"frame":661,"face":{"leye":106,"reye":206,"mouth":302,"cheek":400}},{"frame":663,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":665,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":675,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":680,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":682,"face":{"leye":102,"reye":202,"mouth":323,"cheek":400}},{"frame":685,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":692,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":696,"face":{"leye":106,"reye":206,"mouth":319,"cheek":400}},{"frame":701,"face":{"leye":106,"reye":206,"mouth":305,"cheek":400}},{"frame":707,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":709,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":714,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":718,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":729,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":732,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":736,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":740,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":750,"face":{"leye":105,"reye":205,"mouth":321,"cheek":402}},{"frame":752,"face":{"leye":105,"reye":205,"mouth":0,"cheek":402}},{"frame":753,"face":{"leye":105,"reye":205,"mouth":321,"cheek":402}},{"frame":761,"face":{"leye":105,"reye":205,"mouth":311,"cheek":402}},{"frame":771,"face":{"leye":105,"reye":205,"mouth":323,"cheek":402}},{"frame":774,"face":{"leye":105,"reye":205,"mouth":311,"cheek":402}},{"frame":776,"face":{"leye":105,"reye":205,"mouth":321,"cheek":402}},{"frame":780,"face":{"leye":105,"reye":205,"mouth":311,"cheek":402}},{"frame":784,"face":{"leye":105,"reye":205,"mouth":321,"cheek":402}},{"frame":792,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":795,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":798,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":802,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":814,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":817,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":819,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":826,"face":{"leye":102,"reye":202,"mouth":302,"cheek":400}},{"frame":828,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":836,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":839,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":830,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":850,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":851,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":853,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":856,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":861,"face":{"leye":107,"reye":207,"mouth":316,"cheek":400}},{"frame":864,"face":{"leye":107,"reye":207,"mouth":321,"cheek":400}},{"frame":868,"face":{"leye":107,"reye":207,"mouth":311,"cheek":400}},{"frame":872,"face":{"leye":107,"reye":207,"mouth":323,"cheek":400}},{"frame":875,"face":{"leye":107,"reye":207,"mouth":319,"cheek":400}},{"frame":882,"face":{"leye":105,"reye":205,"mouth":311,"cheek":400}},{"frame":885,"face":{"leye":105,"reye":205,"mouth":321,"cheek":400}},{"frame":890,"face":{"leye":105,"reye":205,"mouth":311,"cheek":400}},{"frame":894,"face":{"leye":105,"reye":205,"mouth":312,"cheek":400}},{"frame":904,"face":{"leye":107,"reye":207,"mouth":311,"cheek":400}},{"frame":911,"face":{"leye":107,"reye":207,"mouth":323,"cheek":400}},{"frame":915,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":924,"face":{"leye":102,"reye":202,"mouth":302,"cheek":400}},{"frame":924,"face":{"leye":106,"reye":206,"mouth":319,"cheek":400}},{"frame":932,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":937,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":940,"face":{"leye":106,"reye":206,"mouth":312,"cheek":400}},{"frame":942,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":948,"face":{"leye":106,"reye":206,"mouth":312,"cheek":400}},{"frame":951,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":955,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":959,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":970,"face":{"leye":105,"reye":205,"mouth":311,"cheek":400}},{"frame":971,"face":{"leye":105,"reye":205,"mouth":302,"cheek":400}},{"frame":973,"face":{"leye":105,"reye":205,"mouth":312,"cheek":400}},{"frame":977,"face":{"leye":105,"reye":205,"mouth":323,"cheek":400}},{"frame":981,"face":{"leye":105,"reye":205,"mouth":312,"cheek":400}},{"frame":992,"face":{"leye":119,"reye":219,"mouth":311,"cheek":402}},{"frame":993,"face":{"leye":119,"reye":219,"mouth":319,"cheek":402}},{"frame":999,"face":{"leye":119,"reye":219,"mouth":321,"cheek":402}},{"frame":1001,"face":{"leye":119,"reye":219,"mouth":310,"cheek":402}},{"frame":1007,"face":{"leye":107,"reye":207,"mouth":321,"cheek":403}},{"frame":1014,"face":{"leye":107,"reye":207,"mouth":316,"cheek":403}},{"frame":1017,"face":{"leye":107,"reye":207,"mouth":310,"cheek":403}},{"frame":1038,"face":{"leye":101,"reye":201,"mouth":302,"cheek":402}},{"frame":1095,"face":{"leye":110,"reye":210,"mouth":302,"cheek":402}},{"frame":1191,"face":{"leye":101,"reye":201,"mouth":304,"cheek":402}}],"solo5":[{"frame":0,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":11,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":15,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}},{"frame":19,"face":{"leye":101,"reye":201,"mouth":312,"cheek":402}},{"frame":25,"face":{"leye":106,"reye":206,"mouth":319,"cheek":402}},{"frame":29,"face":{"leye":106,"reye":206,"mouth":312,"cheek":402}},{"frame":32,"face":{"leye":106,"reye":206,"mouth":319,"cheek":402}},{"frame":35,"face":{"leye":106,"reye":206,"mouth":312,"cheek":402}},{"frame":41,"face":{"leye":106,"reye":206,"mouth":319,"cheek":402}},{"frame":45,"face":{"leye":106,"reye":206,"mouth":312,"cheek":402}},{"frame":51,"face":{"leye":106,"reye":206,"mouth":319,"cheek":402}},{"frame":57,"face":{"leye":106,"reye":206,"mouth":312,"cheek":402}},{"frame":66,"face":{"leye":106,"reye":206,"mouth":319,"cheek":402}},{"frame":69,"face":{"leye":106,"reye":206,"mouth":312,"cheek":402}},{"frame":75,"face":{"leye":106,"reye":206,"mouth":319,"cheek":402}},{"frame":78,"face":{"leye":106,"reye":206,"mouth":312,"cheek":402}},{"frame":82,"face":{"leye":106,"reye":206,"mouth":319,"cheek":402}},{"frame":85,"face":{"leye":106,"reye":206,"mouth":312,"cheek":402}},{"frame":88,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":101,"face":{"leye":110,"reye":210,"mouth":304,"cheek":404}},{"frame":116,"face":{"leye":105,"reye":205,"mouth":319,"cheek":404}},{"frame":120,"face":{"leye":105,"reye":205,"mouth":312,"cheek":404}},{"frame":125,"face":{"leye":105,"reye":205,"mouth":319,"cheek":404}},{"frame":129,"face":{"leye":105,"reye":205,"mouth":312,"cheek":404}},{"frame":132,"face":{"leye":105,"reye":205,"mouth":319,"cheek":404}},{"frame":135,"face":{"leye":105,"reye":205,"mouth":312,"cheek":404}},{"frame":141,"face":{"leye":105,"reye":205,"mouth":319,"cheek":404}},{"frame":145,"face":{"leye":105,"reye":205,"mouth":312,"cheek":404}},{"frame":152,"face":{"leye":105,"reye":205,"mouth":319,"cheek":404}},{"frame":158,"face":{"leye":105,"reye":205,"mouth":312,"cheek":404}},{"frame":166,"face":{"leye":105,"reye":205,"mouth":319,"cheek":404}},{"frame":169,"face":{"leye":105,"reye":205,"mouth":312,"cheek":404}},{"frame":175,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":178,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":182,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":185,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":189,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":204,"face":{"leye":101,"reye":206,"mouth":304,"cheek":400}},{"frame":214,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":219,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":226,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":230,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":234,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":237,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":240,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":242,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":244,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":245,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":248,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":251,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":258,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":263,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":266,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":267,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":270,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":273,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":276,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":277,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":281,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":287,"face":{"leye":117,"reye":217,"mouth":319,"cheek":400}},{"frame":289,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":291,"face":{"leye":117,"reye":217,"mouth":319,"cheek":400}},{"frame":293,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":294,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":298,"face":{"leye":117,"reye":217,"mouth":323,"cheek":400}},{"frame":302,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":308,"face":{"leye":117,"reye":217,"mouth":319,"cheek":400}},{"frame":316,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":322,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":326,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":331,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":333,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":334,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":337,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":339,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":340,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":342,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":343,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":345,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":346,"face":{"leye":105,"reye":205,"mouth":319,"cheek":402}},{"frame":350,"face":{"leye":105,"reye":205,"mouth":323,"cheek":402}},{"frame":353,"face":{"leye":105,"reye":205,"mouth":311,"cheek":402}},{"frame":359,"face":{"leye":112,"reye":212,"mouth":304,"cheek":402}},{"frame":363,"face":{"leye":112,"reye":212,"mouth":311,"cheek":402}},{"frame":365,"face":{"leye":112,"reye":212,"mouth":319,"cheek":402}},{"frame":366,"face":{"leye":112,"reye":212,"mouth":311,"cheek":402}},{"frame":369,"face":{"leye":112,"reye":212,"mouth":310,"cheek":402}},{"frame":371,"face":{"leye":112,"reye":212,"mouth":311,"cheek":402}},{"frame":374,"face":{"leye":112,"reye":212,"mouth":304,"cheek":402}},{"frame":377,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":383,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":389,"face":{"leye":111,"reye":201,"mouth":311,"cheek":400}},{"frame":391,"face":{"leye":111,"reye":201,"mouth":304,"cheek":400}},{"frame":392,"face":{"leye":111,"reye":201,"mouth":311,"cheek":400}},{"frame":394,"face":{"leye":111,"reye":201,"mouth":304,"cheek":400}},{"frame":396,"face":{"leye":111,"reye":201,"mouth":311,"cheek":400}},{"frame":402,"face":{"leye":111,"reye":201,"mouth":323,"cheek":400}},{"frame":406,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":411,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":415,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":424,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":427,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":434,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":437,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":439,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":440,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":444,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":447,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":450,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":455,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":458,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":459,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":462,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":465,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":474,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":478,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":487,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":489,"face":{"leye":106,"reye":206,"mouth":321,"cheek":402}},{"frame":491,"face":{"leye":106,"reye":206,"mouth":323,"cheek":402}},{"frame":500,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":503,"face":{"leye":106,"reye":206,"mouth":312,"cheek":402}},{"frame":513,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":515,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":518,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":521,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":525,"face":{"leye":102,"reye":202,"mouth":323,"cheek":400}},{"frame":527,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":531,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":535,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":537,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":541,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":544,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":545,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":546,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":549,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":550,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":553,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":557,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":559,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":562,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":566,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":574,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":577,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":585,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":587,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":591,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":593,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":597,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":600,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":604,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":609,"face":{"leye":106,"reye":206,"mouth":319,"cheek":404}},{"frame":617,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":618,"face":{"leye":101,"reye":201,"mouth":304,"cheek":402}},{"frame":619,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}},{"frame":622,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":624,"face":{"leye":101,"reye":201,"mouth":321,"cheek":402}},{"frame":625,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":628,"face":{"leye":101,"reye":201,"mouth":304,"cheek":402}},{"frame":629,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":630,"face":{"leye":101,"reye":201,"mouth":304,"cheek":402}},{"frame":632,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":634,"face":{"leye":101,"reye":201,"mouth":321,"cheek":402}},{"frame":636,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}},{"frame":638,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":641,"face":{"leye":101,"reye":201,"mouth":312,"cheek":402}},{"frame":647,"face":{"leye":101,"reye":201,"mouth":321,"cheek":402}},{"frame":653,"face":{"leye":101,"reye":201,"mouth":319,"cheek":402}},{"frame":659,"face":{"leye":101,"reye":201,"mouth":321,"cheek":402}},{"frame":666,"face":{"leye":110,"reye":210,"mouth":321,"cheek":402}},{"frame":667,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":669,"face":{"leye":110,"reye":210,"mouth":321,"cheek":402}},{"frame":671,"face":{"leye":110,"reye":210,"mouth":319,"cheek":402}},{"frame":673,"face":{"leye":110,"reye":210,"mouth":321,"cheek":402}},{"frame":674,"face":{"leye":110,"reye":210,"mouth":323,"cheek":402}},{"frame":677,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":679,"face":{"leye":110,"reye":210,"mouth":321,"cheek":402}},{"frame":680,"face":{"leye":110,"reye":210,"mouth":323,"cheek":402}},{"frame":683,"face":{"leye":110,"reye":210,"mouth":311,"cheek":402}},{"frame":686,"face":{"leye":110,"reye":210,"mouth":321,"cheek":402}},{"frame":690,"face":{"leye":102,"reye":202,"mouth":321,"cheek":402}},{"frame":692,"face":{"leye":102,"reye":202,"mouth":319,"cheek":402}},{"frame":698,"face":{"leye":102,"reye":202,"mouth":311,"cheek":402}},{"frame":711,"face":{"leye":101,"reye":206,"mouth":323,"cheek":402}},{"frame":712,"face":{"leye":101,"reye":206,"mouth":311,"cheek":402}},{"frame":714,"face":{"leye":101,"reye":206,"mouth":321,"cheek":402}},{"frame":717,"face":{"leye":106,"reye":206,"mouth":312,"cheek":404}},{"frame":724,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":727,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":730,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":732,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":734,"face":{"leye":106,"reye":206,"mouth":323,"cheek":404}},{"frame":737,"face":{"leye":106,"reye":206,"mouth":312,"cheek":404}},{"frame":739,"face":{"leye":106,"reye":206,"mouth":323,"cheek":404}},{"frame":742,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":749,"face":{"leye":106,"reye":206,"mouth":323,"cheek":404}},{"frame":754,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":759,"face":{"leye":106,"reye":206,"mouth":321,"cheek":404}},{"frame":761,"face":{"leye":106,"reye":206,"mouth":311,"cheek":404}},{"frame":764,"face":{"leye":106,"reye":206,"mouth":304,"cheek":404}},{"frame":766,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":767,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":770,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":774,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":776,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":777,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":779,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":780,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":782,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":783,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":786,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":792,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":799,"face":{"leye":107,"reye":207,"mouth":311,"cheek":404}},{"frame":811,"face":{"leye":107,"reye":207,"mouth":323,"cheek":404}},{"frame":813,"face":{"leye":107,"reye":207,"mouth":311,"cheek":404}},{"frame":817,"face":{"leye":107,"reye":207,"mouth":321,"cheek":404}},{"frame":820,"face":{"leye":105,"reye":205,"mouth":319,"cheek":404}},{"frame":824,"face":{"leye":105,"reye":205,"mouth":312,"cheek":404}},{"frame":830,"face":{"leye":105,"reye":205,"mouth":319,"cheek":404}},{"frame":833,"face":{"leye":105,"reye":205,"mouth":312,"cheek":404}},{"frame":836,"face":{"leye":105,"reye":205,"mouth":319,"cheek":404}},{"frame":839,"face":{"leye":105,"reye":205,"mouth":312,"cheek":404}},{"frame":845,"face":{"leye":105,"reye":205,"mouth":319,"cheek":404}},{"frame":848,"face":{"leye":105,"reye":205,"mouth":312,"cheek":404}},{"frame":854,"face":{"leye":105,"reye":205,"mouth":319,"cheek":404}},{"frame":862,"face":{"leye":105,"reye":205,"mouth":312,"cheek":404}},{"frame":871,"face":{"leye":105,"reye":205,"mouth":319,"cheek":404}},{"frame":874,"face":{"leye":105,"reye":205,"mouth":312,"cheek":404}},{"frame":880,"face":{"leye":105,"reye":205,"mouth":319,"cheek":404}},{"frame":882,"face":{"leye":105,"reye":205,"mouth":312,"cheek":404}},{"frame":886,"face":{"leye":105,"reye":205,"mouth":319,"cheek":404}},{"frame":889,"face":{"leye":105,"reye":205,"mouth":312,"cheek":404}},{"frame":891,"face":{"leye":102,"reye":202,"mouth":311,"cheek":402}},{"frame":895,"face":{"leye":102,"reye":202,"mouth":321,"cheek":402}},{"frame":898,"face":{"leye":102,"reye":202,"mouth":311,"cheek":402}},{"frame":903,"face":{"leye":102,"reye":202,"mouth":319,"cheek":402}},{"frame":910,"face":{"leye":107,"reye":207,"mouth":312,"cheek":404}},{"frame":911,"face":{"leye":107,"reye":207,"mouth":323,"cheek":404}},{"frame":912,"face":{"leye":107,"reye":207,"mouth":310,"cheek":404}}],"tkmk":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":8,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":73,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":78,"face":{"leye":101,"reye":206,"mouth":304,"cheek":402}},{"frame":79,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":81,"face":{"leye":101,"reye":201,"mouth":310,"cheek":400}},{"frame":87,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":101,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":113,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":114,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":117,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":118,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":120,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":122,"face":{"leye":106,"reye":206,"mouth":312,"cheek":400}},{"frame":124,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":125,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":128,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":138,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":147,"face":{"leye":102,"reye":206,"mouth":304,"cheek":402}},{"frame":150,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":152,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":153,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":155,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":156,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":160,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":163,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":166,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":168,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":170,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":171,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":173,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":175,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":176,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":178,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":180,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":181,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":184,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":188,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":191,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":193,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":197,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":198,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":201,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":204,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":206,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":207,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":208,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":211,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":213,"face":{"leye":102,"reye":202,"mouth":0,"cheek":400}},{"frame":214,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":216,"face":{"leye":102,"reye":202,"mouth":323,"cheek":400}},{"frame":217,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":226,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":227,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":229,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":231,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":232,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":234,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":238,"face":{"leye":106,"reye":206,"mouth":323,"cheek":402}},{"frame":241,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":246,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":248,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":251,"face":{"leye":101,"reye":206,"mouth":323,"cheek":402}},{"frame":256,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":258,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":260,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":262,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":265,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":269,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":275,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":278,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":281,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":283,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":285,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":286,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":287,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":288,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":291,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":293,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":296,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":298,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":304,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":306,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":309,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":311,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":313,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":316,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":318,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":320,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":326,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":328,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":332,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":335,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":348,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":354,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":358,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":361,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":364,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":367,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":374,"face":{"leye":106,"reye":201,"mouth":323,"cheek":402}},{"frame":376,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":387,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":388,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":391,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":395,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":402,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":404,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":406,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":408,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":410,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":411,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":413,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":416,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":420,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":421,"face":{"leye":102,"reye":202,"mouth":323,"cheek":400}},{"frame":423,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":427,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":433,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":438,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":443,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":444,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":447,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":448,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":451,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":456,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":460,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":465,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":471,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":474,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":483,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":485,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":494,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":495,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":496,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":498,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":500,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":504,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":505,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":506,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":507,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":508,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":510,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":512,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":520,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":525,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":528,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":534,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":538,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":539,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":545,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":548,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":550,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":552,"face":{"leye":106,"reye":201,"mouth":311,"cheek":400}},{"frame":556,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":568,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":573,"face":{"leye":101,"reye":206,"mouth":319,"cheek":402}},{"frame":576,"face":{"leye":101,"reye":206,"mouth":319,"cheek":400}},{"frame":577,"face":{"leye":101,"reye":206,"mouth":304,"cheek":400}},{"frame":579,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":581,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":582,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":585,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":587,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":591,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":592,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":595,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":598,"face":{"leye":101,"reye":206,"mouth":321,"cheek":400}},{"frame":605,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":608,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":609,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":611,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":613,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":617,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":618,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":619,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":621,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":624,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":627,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":629,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":632,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":634,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":636,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":637,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":639,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":641,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":642,"face":{"leye":102,"reye":202,"mouth":312,"cheek":400}},{"frame":645,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":646,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":649,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":650,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":655,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":660,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":664,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":666,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":668,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":673,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":675,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":676,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":677,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":679,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":680,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":681,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":683,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":685,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":688,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":690,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":691,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":693,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":696,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":697,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":698,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":702,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":705,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":711,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":716,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":718,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":720,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":721,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":723,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":724,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":725,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":727,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":730,"face":{"leye":106,"reye":201,"mouth":312,"cheek":402}},{"frame":734,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":735,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":737,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":741,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":745,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":749,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":751,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":753,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":756,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":761,"face":{"leye":101,"reye":201,"mouth":0,"cheek":400}},{"frame":762,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":765,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":771,"face":{"leye":106,"reye":201,"mouth":311,"cheek":400}},{"frame":772,"face":{"leye":106,"reye":201,"mouth":319,"cheek":400}},{"frame":775,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":776,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":780,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":782,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":786,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":788,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":790,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":791,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":793,"face":{"leye":102,"reye":206,"mouth":321,"cheek":400}},{"frame":794,"face":{"leye":102,"reye":206,"mouth":0,"cheek":400}},{"frame":795,"face":{"leye":102,"reye":206,"mouth":316,"cheek":400}},{"frame":797,"face":{"leye":101,"reye":201,"mouth":323,"cheek":400}},{"frame":807,"face":{"leye":106,"reye":206,"mouth":323,"cheek":402}},{"frame":808,"face":{"leye":106,"reye":206,"mouth":304,"cheek":402}},{"frame":813,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":823,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":825,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":841,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":842,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":843,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}},{"frame":844,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":846,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":864,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":866,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":871,"face":{"leye":101,"reye":201,"mouth":304,"cheek":400}}]},"videoDb":[{"id":1,"title":"Call&Response前半","cover":"C&R01"},{"id":2,"title":"Call&Response后半","cover":"C&R02"},{"id":3,"title":"Call&Response前半(纯享)","cover":"C&R11"},{"id":4,"title":"Call&Response后半(纯享)","cover":"C&R12"},{"id":5,"title":"TV一期第六话Part1","cover":"TVS101"},{"id":6,"title":"TV一期第六话Part2","cover":"TVS102"},{"id":7,"title":"TV一期第六话Part3","cover":"TVS103"}],"videoTimelines":{"C&R01":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":302,"cheek":400}},{"frame":20,"face":{"leye":101,"reye":201,"mouth":326,"cheek":400}}],"C&R02":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":326,"cheek":400}},{"frame":8,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":62,"face":{"leye":101,"reye":201,"mouth":328,"cheek":400}},{"frame":110,"face":{"leye":110,"reye":210,"mouth":302,"cheek":404}},{"frame":141,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":205,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":245,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}}],"C&R11":[{"frame":0,"face":{"leye":102,"reye":202,"mouth":302,"cheek":400}},{"frame":20,"face":{"leye":101,"reye":201,"mouth":326,"cheek":400}}],"C&R12":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":326,"cheek":400}},{"frame":8,"face":{"leye":106,"reye":206,"mouth":302,"cheek":402}},{"frame":62,"face":{"leye":101,"reye":201,"mouth":328,"cheek":400}},{"frame":110,"face":{"leye":110,"reye":210,"mouth":302,"cheek":404}}],"TVS101":[{"frame":0,"face":{"leye":0,"reye":0,"mouth":0,"cheek":400}},{"frame":116,"face":{"leye":101,"reye":201,"mouth":301,"cheek":400}},{"frame":204,"face":{"leye":103,"reye":203,"mouth":302,"cheek":403}},{"frame":233,"face":{"leye":103,"reye":203,"mouth":310,"cheek":404}}],"TVS102":[{"frame":0,"face":{"leye":103,"reye":203,"mouth":310,"cheek":403}},{"frame":5,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":22,"face":{"leye":101,"reye":201,"mouth":310,"cheek":400}},{"frame":34,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":35,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}},{"frame":36,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":37,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":39,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":40,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":42,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":46,"face":{"leye":106,"reye":206,"mouth":317,"cheek":400}},{"frame":47,"face":{"leye":106,"reye":206,"mouth":319,"cheek":403}},{"frame":48,"face":{"leye":106,"reye":206,"mouth":317,"cheek":403}},{"frame":52,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":55,"face":{"leye":106,"reye":206,"mouth":310,"cheek":403}},{"frame":57,"face":{"leye":106,"reye":206,"mouth":302,"cheek":403}},{"frame":58,"face":{"leye":106,"reye":206,"mouth":317,"cheek":403}},{"frame":59,"face":{"leye":102,"reye":202,"mouth":317,"cheek":403}},{"frame":60,"face":{"leye":106,"reye":206,"mouth":302,"cheek":400}},{"frame":64,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":67,"face":{"leye":110,"reye":210,"mouth":316,"cheek":403}},{"frame":68,"face":{"leye":102,"reye":202,"mouth":310,"cheek":400}},{"frame":72,"face":{"leye":106,"reye":206,"mouth":319,"cheek":400}},{"frame":73,"face":{"leye":106,"reye":206,"mouth":316,"cheek":400}},{"frame":75,"face":{"leye":110,"reye":210,"mouth":316,"cheek":400}},{"frame":76,"face":{"leye":101,"reye":202,"mouth":316,"cheek":400}},{"frame":79,"face":{"leye":106,"reye":206,"mouth":306,"cheek":400}},{"frame":80,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":82,"face":{"leye":105,"reye":205,"mouth":323,"cheek":403}},{"frame":85,"face":{"leye":105,"reye":205,"mouth":302,"cheek":403}},{"frame":87,"face":{"leye":102,"reye":202,"mouth":302,"cheek":403}},{"frame":88,"face":{"leye":107,"reye":207,"mouth":311,"cheek":403}},{"frame":93,"face":{"leye":107,"reye":207,"mouth":304,"cheek":403}},{"frame":117,"face":{"leye":106,"reye":202,"mouth":311,"cheek":403}},{"frame":144,"face":{"leye":106,"reye":202,"mouth":304,"cheek":403}},{"frame":149,"face":{"leye":107,"reye":207,"mouth":304,"cheek":403}},{"frame":168,"face":{"leye":107,"reye":207,"mouth":311,"cheek":403}},{"frame":172,"face":{"leye":107,"reye":207,"mouth":304,"cheek":403}},{"frame":182,"face":{"leye":105,"reye":205,"mouth":323,"cheek":403}},{"frame":183,"face":{"leye":105,"reye":205,"mouth":311,"cheek":403}},{"frame":184,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":186,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":187,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":192,"face":{"leye":106,"reye":206,"mouth":304,"cheek":400}},{"frame":196,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":198,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":201,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":203,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":206,"face":{"leye":119,"reye":219,"mouth":316,"cheek":400}},{"frame":207,"face":{"leye":119,"reye":219,"mouth":319,"cheek":400}},{"frame":210,"face":{"leye":119,"reye":219,"mouth":316,"cheek":400}},{"frame":214,"face":{"leye":119,"reye":219,"mouth":311,"cheek":400}},{"frame":217,"face":{"leye":106,"reye":206,"mouth":323,"cheek":400}},{"frame":221,"face":{"leye":106,"reye":206,"mouth":310,"cheek":400}},{"frame":223,"face":{"leye":101,"reye":201,"mouth":310,"cheek":400}},{"frame":224,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":226,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":230,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":235,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":238,"face":{"leye":111,"reye":211,"mouth":311,"cheek":400}},{"frame":244,"face":{"leye":111,"reye":211,"mouth":328,"cheek":400}},{"frame":251,"face":{"leye":119,"reye":219,"mouth":319,"cheek":400}},{"frame":253,"face":{"leye":119,"reye":219,"mouth":311,"cheek":400}},{"frame":254,"face":{"leye":107,"reye":207,"mouth":311,"cheek":400}},{"frame":256,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":258,"face":{"leye":117,"reye":217,"mouth":302,"cheek":400}},{"frame":259,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":261,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":262,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":267,"face":{"leye":117,"reye":217,"mouth":302,"cheek":400}},{"frame":268,"face":{"leye":117,"reye":217,"mouth":310,"cheek":400}},{"frame":272,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":276,"face":{"leye":117,"reye":217,"mouth":310,"cheek":400}},{"frame":277,"face":{"leye":110,"reye":210,"mouth":310,"cheek":400}},{"frame":279,"face":{"leye":119,"reye":220,"mouth":310,"cheek":400}},{"frame":280,"face":{"leye":119,"reye":220,"mouth":319,"cheek":400}},{"frame":281,"face":{"leye":119,"reye":220,"mouth":316,"cheek":400}},{"frame":284,"face":{"leye":119,"reye":220,"mouth":319,"cheek":400}},{"frame":287,"face":{"leye":119,"reye":220,"mouth":302,"cheek":400}},{"frame":288,"face":{"leye":119,"reye":220,"mouth":311,"cheek":400}},{"frame":292,"face":{"leye":119,"reye":220,"mouth":322,"cheek":400}},{"frame":297,"face":{"leye":119,"reye":220,"mouth":328,"cheek":400}},{"frame":304,"face":{"leye":106,"reye":206,"mouth":328,"cheek":402}},{"frame":305,"face":{"leye":106,"reye":206,"mouth":321,"cheek":402}},{"frame":306,"face":{"leye":107,"reye":207,"mouth":323,"cheek":402}},{"frame":309,"face":{"leye":107,"reye":207,"mouth":311,"cheek":402}},{"frame":310,"face":{"leye":107,"reye":207,"mouth":310,"cheek":402}},{"frame":311,"face":{"leye":110,"reye":210,"mouth":310,"cheek":403}},{"frame":312,"face":{"leye":119,"reye":219,"mouth":311,"cheek":402}},{"frame":317,"face":{"leye":119,"reye":219,"mouth":302,"cheek":402}},{"frame":320,"face":{"leye":119,"reye":219,"mouth":319,"cheek":402}},{"frame":327,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":328,"face":{"leye":110,"reye":210,"mouth":312,"cheek":400}},{"frame":332,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}},{"frame":334,"face":{"leye":101,"reye":201,"mouth":312,"cheek":400}},{"frame":339,"face":{"leye":122,"reye":222,"mouth":312,"cheek":400}},{"frame":340,"face":{"leye":122,"reye":222,"mouth":311,"cheek":400}},{"frame":342,"face":{"leye":122,"reye":222,"mouth":316,"cheek":400}},{"frame":345,"face":{"leye":122,"reye":222,"mouth":322,"cheek":400}},{"frame":346,"face":{"leye":110,"reye":210,"mouth":322,"cheek":400}},{"frame":347,"face":{"leye":106,"reye":206,"mouth":314,"cheek":403}},{"frame":349,"face":{"leye":106,"reye":206,"mouth":328,"cheek":403}},{"frame":350,"face":{"leye":106,"reye":206,"mouth":314,"cheek":403}},{"frame":352,"face":{"leye":106,"reye":206,"mouth":322,"cheek":403}},{"frame":356,"face":{"leye":106,"reye":206,"mouth":328,"cheek":403}},{"frame":360,"face":{"leye":106,"reye":206,"mouth":319,"cheek":403}},{"frame":361,"face":{"leye":116,"reye":216,"mouth":319,"cheek":402}},{"frame":367,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":368,"face":{"leye":116,"reye":216,"mouth":319,"cheek":402}},{"frame":369,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":373,"face":{"leye":116,"reye":216,"mouth":321,"cheek":402}},{"frame":375,"face":{"leye":116,"reye":216,"mouth":319,"cheek":402}},{"frame":378,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":379,"face":{"leye":116,"reye":216,"mouth":321,"cheek":402}},{"frame":380,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":382,"face":{"leye":116,"reye":216,"mouth":321,"cheek":402}},{"frame":384,"face":{"leye":116,"reye":216,"mouth":311,"cheek":402}},{"frame":386,"face":{"leye":116,"reye":216,"mouth":311,"cheek":400}},{"frame":387,"face":{"leye":101,"reye":201,"mouth":322,"cheek":400}},{"frame":388,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":390,"face":{"leye":117,"reye":217,"mouth":319,"cheek":400}},{"frame":392,"face":{"leye":117,"reye":217,"mouth":317,"cheek":400}},{"frame":393,"face":{"leye":117,"reye":217,"mouth":319,"cheek":400}},{"frame":397,"face":{"leye":117,"reye":217,"mouth":316,"cheek":400}},{"frame":398,"face":{"leye":117,"reye":217,"mouth":314,"cheek":400}},{"frame":401,"face":{"leye":106,"reye":206,"mouth":314,"cheek":400}},{"frame":401,"face":{"leye":106,"reye":206,"mouth":322,"cheek":400}},{"frame":407,"face":{"leye":119,"reye":219,"mouth":322,"cheek":400}},{"frame":408,"face":{"leye":117,"reye":217,"mouth":322,"cheek":400}},{"frame":409,"face":{"leye":108,"reye":209,"mouth":314,"cheek":400}},{"frame":417,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":419,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":422,"face":{"leye":117,"reye":217,"mouth":319,"cheek":400}},{"frame":424,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":428,"face":{"leye":119,"reye":220,"mouth":302,"cheek":400}},{"frame":429,"face":{"leye":119,"reye":220,"mouth":322,"cheek":400}},{"frame":432,"face":{"leye":119,"reye":220,"mouth":328,"cheek":400}},{"frame":444,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":446,"face":{"leye":110,"reye":210,"mouth":302,"cheek":400}},{"frame":448,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":450,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":452,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":454,"face":{"leye":110,"reye":210,"mouth":321,"cheek":400}},{"frame":456,"face":{"leye":110,"reye":210,"mouth":323,"cheek":400}},{"frame":468,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":469,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":470,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":471,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":472,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":474,"face":{"leye":110,"reye":210,"mouth":316,"cheek":400}},{"frame":475,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":476,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":477,"face":{"leye":107,"reye":207,"mouth":311,"cheek":400}},{"frame":478,"face":{"leye":107,"reye":207,"mouth":302,"cheek":400}},{"frame":480,"face":{"leye":107,"reye":207,"mouth":311,"cheek":400}},{"frame":481,"face":{"leye":101,"reye":201,"mouth":328,"cheek":400}},{"frame":483,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":484,"face":{"leye":117,"reye":217,"mouth":311,"cheek":400}},{"frame":486,"face":{"leye":117,"reye":217,"mouth":321,"cheek":400}},{"frame":487,"face":{"leye":108,"reye":209,"mouth":316,"cheek":400}},{"frame":490,"face":{"leye":108,"reye":209,"mouth":321,"cheek":400}},{"frame":495,"face":{"leye":108,"reye":209,"mouth":311,"cheek":400}},{"frame":497,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":498,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":507,"face":{"leye":101,"reye":201,"mouth":302,"cheek":402}},{"frame":509,"face":{"leye":101,"reye":201,"mouth":311,"cheek":402}},{"frame":511,"face":{"leye":119,"reye":219,"mouth":321,"cheek":402}},{"frame":516,"face":{"leye":119,"reye":219,"mouth":323,"cheek":402}},{"frame":517,"face":{"leye":119,"reye":219,"mouth":316,"cheek":402}},{"frame":520,"face":{"leye":119,"reye":219,"mouth":311,"cheek":402}},{"frame":523,"face":{"leye":119,"reye":219,"mouth":302,"cheek":402}},{"frame":525,"face":{"leye":119,"reye":219,"mouth":311,"cheek":402}},{"frame":527,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":539,"face":{"leye":106,"reye":202,"mouth":311,"cheek":403}},{"frame":545,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":549,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":550,"face":{"leye":106,"reye":206,"mouth":311,"cheek":400}},{"frame":552,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":555,"face":{"leye":110,"reye":210,"mouth":319,"cheek":400}},{"frame":556,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":558,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":559,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":560,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":562,"face":{"leye":106,"reye":206,"mouth":321,"cheek":402}},{"frame":564,"face":{"leye":106,"reye":206,"mouth":311,"cheek":402}},{"frame":565,"face":{"leye":106,"reye":206,"mouth":319,"cheek":402}},{"frame":567,"face":{"leye":101,"reye":201,"mouth":319,"cheek":403}},{"frame":569,"face":{"leye":101,"reye":201,"mouth":311,"cheek":403}},{"frame":570,"face":{"leye":101,"reye":201,"mouth":321,"cheek":403}},{"frame":571,"face":{"leye":101,"reye":201,"mouth":311,"cheek":403}},{"frame":572,"face":{"leye":101,"reye":201,"mouth":321,"cheek":403}},{"frame":574,"face":{"leye":106,"reye":206,"mouth":321,"cheek":403}},{"frame":575,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":577,"face":{"leye":106,"reye":206,"mouth":316,"cheek":403}},{"frame":578,"face":{"leye":110,"reye":210,"mouth":316,"cheek":403}},{"frame":579,"face":{"leye":101,"reye":201,"mouth":321,"cheek":403}},{"frame":581,"face":{"leye":101,"reye":201,"mouth":316,"cheek":403}},{"frame":583,"face":{"leye":101,"reye":201,"mouth":321,"cheek":403}},{"frame":586,"face":{"leye":101,"reye":201,"mouth":311,"cheek":403}},{"frame":589,"face":{"leye":101,"reye":201,"mouth":312,"cheek":403}},{"frame":589,"face":{"leye":101,"reye":201,"mouth":312,"cheek":403}},{"frame":591,"face":{"leye":101,"reye":201,"mouth":321,"cheek":403}},{"frame":597,"face":{"leye":101,"reye":201,"mouth":316,"cheek":403}},{"frame":600,"face":{"leye":106,"reye":206,"mouth":313,"cheek":403}},{"frame":604,"face":{"leye":110,"reye":210,"mouth":313,"cheek":403}},{"frame":605,"face":{"leye":106,"reye":206,"mouth":321,"cheek":400}},{"frame":606,"face":{"leye":102,"reye":202,"mouth":321,"cheek":400}},{"frame":607,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":609,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":615,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":616,"face":{"leye":102,"reye":202,"mouth":311,"cheek":400}},{"frame":619,"face":{"leye":102,"reye":202,"mouth":310,"cheek":400}},{"frame":620,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":624,"face":{"leye":110,"reye":210,"mouth":321,"cheek":403}},{"frame":627,"face":{"leye":110,"reye":210,"mouth":311,"cheek":403}},{"frame":629,"face":{"leye":110,"reye":210,"mouth":302,"cheek":403}},{"frame":634,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":636,"face":{"leye":106,"reye":206,"mouth":321,"cheek":403}},{"frame":637,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":639,"face":{"leye":106,"reye":206,"mouth":319,"cheek":403}},{"frame":643,"face":{"leye":106,"reye":206,"mouth":321,"cheek":403}},{"frame":644,"face":{"leye":105,"reye":205,"mouth":321,"cheek":403}},{"frame":646,"face":{"leye":105,"reye":205,"mouth":311,"cheek":403}},{"frame":648,"face":{"leye":105,"reye":205,"mouth":321,"cheek":403}},{"frame":650,"face":{"leye":105,"reye":205,"mouth":311,"cheek":403}},{"frame":651,"face":{"leye":105,"reye":205,"mouth":312,"cheek":403}},{"frame":656,"face":{"leye":102,"reye":202,"mouth":304,"cheek":403}},{"frame":657,"face":{"leye":102,"reye":202,"mouth":317,"cheek":403}},{"frame":658,"face":{"leye":110,"reye":210,"mouth":317,"cheek":403}},{"frame":660,"face":{"leye":119,"reye":219,"mouth":321,"cheek":403}},{"frame":662,"face":{"leye":106,"reye":206,"mouth":321,"cheek":403}},{"frame":665,"face":{"leye":119,"reye":219,"mouth":321,"cheek":403}},{"frame":671,"face":{"leye":119,"reye":219,"mouth":319,"cheek":403}},{"frame":673,"face":{"leye":119,"reye":219,"mouth":311,"cheek":403}},{"frame":675,"face":{"leye":119,"reye":219,"mouth":321,"cheek":403}},{"frame":678,"face":{"leye":119,"reye":219,"mouth":311,"cheek":403}},{"frame":679,"face":{"leye":119,"reye":219,"mouth":321,"cheek":403}},{"frame":681,"face":{"leye":119,"reye":219,"mouth":302,"cheek":403}},{"frame":682,"face":{"leye":119,"reye":219,"mouth":311,"cheek":403}},{"frame":684,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":686,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":687,"face":{"leye":110,"reye":210,"mouth":302,"cheek":403}},{"frame":689,"face":{"leye":102,"reye":202,"mouth":319,"cheek":403}},{"frame":690,"face":{"leye":106,"reye":202,"mouth":302,"cheek":403}},{"frame":691,"face":{"leye":106,"reye":202,"mouth":319,"cheek":403}},{"frame":692,"face":{"leye":106,"reye":202,"mouth":310,"cheek":403}},{"frame":694,"face":{"leye":102,"reye":202,"mouth":310,"cheek":403}},{"frame":696,"face":{"leye":102,"reye":202,"mouth":311,"cheek":403}},{"frame":697,"face":{"leye":102,"reye":206,"mouth":311,"cheek":403}},{"frame":698,"face":{"leye":102,"reye":206,"mouth":316,"cheek":403}},{"frame":699,"face":{"leye":102,"reye":206,"mouth":319,"cheek":403}},{"frame":700,"face":{"leye":102,"reye":206,"mouth":316,"cheek":403}},{"frame":702,"face":{"leye":110,"reye":210,"mouth":321,"cheek":403}},{"frame":704,"face":{"leye":119,"reye":219,"mouth":321,"cheek":403}},{"frame":709,"face":{"leye":119,"reye":219,"mouth":311,"cheek":403}},{"frame":714,"face":{"leye":110,"reye":210,"mouth":311,"cheek":403}},{"frame":715,"face":{"leye":119,"reye":219,"mouth":319,"cheek":403}},{"frame":718,"face":{"leye":119,"reye":219,"mouth":311,"cheek":403}},{"frame":722,"face":{"leye":119,"reye":219,"mouth":302,"cheek":403}},{"frame":724,"face":{"leye":119,"reye":219,"mouth":311,"cheek":403}},{"frame":727,"face":{"leye":106,"reye":201,"mouth":311,"cheek":403}},{"frame":729,"face":{"leye":106,"reye":201,"mouth":321,"cheek":403}},{"frame":730,"face":{"leye":106,"reye":201,"mouth":319,"cheek":403}},{"frame":734,"face":{"leye":106,"reye":201,"mouth":321,"cheek":403}},{"frame":736,"face":{"leye":106,"reye":201,"mouth":302,"cheek":403}},{"frame":737,"face":{"leye":106,"reye":201,"mouth":311,"cheek":403}},{"frame":738,"face":{"leye":106,"reye":201,"mouth":312,"cheek":403}},{"frame":740,"face":{"leye":106,"reye":201,"mouth":302,"cheek":403}},{"frame":742,"face":{"leye":101,"reye":201,"mouth":306,"cheek":403}},{"frame":743,"face":{"leye":101,"reye":201,"mouth":316,"cheek":403}},{"frame":744,"face":{"leye":101,"reye":201,"mouth":310,"cheek":403}},{"frame":747,"face":{"leye":101,"reye":201,"mouth":311,"cheek":403}},{"frame":748,"face":{"leye":101,"reye":201,"mouth":321,"cheek":403}},{"frame":752,"face":{"leye":101,"reye":201,"mouth":312,"cheek":403}},{"frame":753,"face":{"leye":101,"reye":201,"mouth":319,"cheek":403}},{"frame":754,"face":{"leye":101,"reye":201,"mouth":321,"cheek":403}},{"frame":757,"face":{"leye":101,"reye":201,"mouth":311,"cheek":403}},{"frame":762,"face":{"leye":101,"reye":201,"mouth":312,"cheek":403}},{"frame":765,"face":{"leye":106,"reye":206,"mouth":312,"cheek":403}},{"frame":774,"face":{"leye":110,"reye":210,"mouth":311,"cheek":400}},{"frame":776,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":777,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":778,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":780,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":781,"face":{"leye":101,"reye":201,"mouth":319,"cheek":400}},{"frame":783,"face":{"leye":101,"reye":201,"mouth":317,"cheek":400}},{"frame":784,"face":{"leye":106,"reye":206,"mouth":317,"cheek":400}},{"frame":785,"face":{"leye":106,"reye":206,"mouth":316,"cheek":403}},{"frame":786,"face":{"leye":106,"reye":206,"mouth":319,"cheek":403}},{"frame":787,"face":{"leye":106,"reye":206,"mouth":317,"cheek":403}},{"frame":790,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":794,"face":{"leye":106,"reye":206,"mouth":321,"cheek":403}},{"frame":796,"face":{"leye":106,"reye":206,"mouth":302,"cheek":403}},{"frame":797,"face":{"leye":110,"reye":210,"mouth":316,"cheek":403}},{"frame":799,"face":{"leye":101,"reye":201,"mouth":302,"cheek":400}},{"frame":801,"face":{"leye":101,"reye":201,"mouth":321,"cheek":400}},{"frame":803,"face":{"leye":101,"reye":201,"mouth":311,"cheek":400}},{"frame":804,"face":{"leye":101,"reye":201,"mouth":316,"cheek":400}},{"frame":805,"face":{"leye":110,"reye":210,"mouth":304,"cheek":400}},{"frame":806,"face":{"leye":102,"reye":202,"mouth":302,"cheek":400}},{"frame":807,"face":{"leye":102,"reye":202,"mouth":310,"cheek":400}},{"frame":809,"face":{"leye":102,"reye":202,"mouth":319,"cheek":400}},{"frame":811,"face":{"leye":102,"reye":202,"mouth":316,"cheek":400}},{"frame":816,"face":{"leye":102,"reye":202,"mouth":304,"cheek":400}},{"frame":818,"face":{"leye":110,"reye":210,"mouth":321,"cheek":402}},{"frame":819,"face":{"leye":105,"reye":205,"mouth":310,"cheek":403}},{"frame":823,"face":{"leye":110,"reye":210,"mouth":306,"cheek":403}},{"frame":824,"face":{"leye":107,"reye":207,"mouth":306,"cheek":403}},{"frame":828,"face":{"leye":107,"reye":207,"mouth":311,"cheek":403}},{"frame":833,"face":{"leye":107,"reye":207,"mouth":304,"cheek":403}},{"frame":855,"face":{"leye":107,"reye":207,"mouth":311,"cheek":403}},{"frame":874,"face":{"leye":107,"reye":207,"mouth":302,"cheek":403}},{"frame":880,"face":{"leye":102,"reye":206,"mouth":310,"cheek":403}},{"frame":905,"face":{"leye":110,"reye":210,"mouth":302,"cheek":403}},{"frame":909,"face":{"leye":106,"reye":206,"mouth":310,"cheek":403}},{"frame":936,"face":{"leye":102,"reye":202,"mouth":311,"cheek":403}},{"frame":951,"face":{"leye":106,"reye":206,"mouth":311,"cheek":403}},{"frame":957,"face":{"leye":119,"reye":219,"mouth":311,"cheek":403}},{"frame":968,"face":{"leye":102,"reye":202,"mouth":306,"cheek":403}},{"frame":968,"face":{"leye":102,"reye":202,"mouth":306,"cheek":403}}],"TVS103":[{"frame":0,"face":{"leye":101,"reye":201,"mouth":310,"cheek":401}},{"frame":156,"face":{"leye":101,"reye":201,"mouth":302,"cheek":401}},{"frame":229,"face":{"leye":106,"reye":206,"mouth":310,"cheek":402}}]}};
// UNITY_DB_END
// APP_RUNTIME_BEGIN
(function(){
'use strict';

const DEFAULT_FACES = [{"name":"默认 01 惊讶眨眼大嘴","hex":"0000000000700408804044020020080100200000001002000000006180027900080400402004F20030C0000000000","type":"default","locked":true,"builtin":true,"default_id":"web_default_00"},{"name":"默认 02 眼镜方嘴","hex":"00000000000000000000300301A0160780780C00E000014000020000000000000FFC00402003FC000000000000000","type":"default","locked":true,"builtin":true,"default_id":"web_default_01"},{"name":"默认 03 困惑挑眉","hex":"0000000000000000000000000000000800041E01E000000000000A00140000000408001F800000000000000000000","type":"default","locked":true,"builtin":true,"default_id":"web_default_02"},{"name":"默认 04 难过斜眼","hex":"000000000000000000003000C0C00C0300400C00C00000C000000A001401FE0004080010800090000600000000000","type":"default","locked":true,"builtin":true,"default_id":"web_default_03"},{"name":"默认 05 中性偷笑","hex":"00000000000000000000300300C00C0300300C00C000000000000A00140201000408001F800000000000000000000","type":"default","locked":true,"builtin":true,"default_id":"web_default_04"},{"name":"默认 06 开心眯眼","hex":"00000000000000000000000000C00C03C0F006018000000000000540A800840003F00010800204000000000000000","type":"default","locked":true,"builtin":true,"default_id":"web_default_05"},{"name":"默认 07 宽眉小嘴","hex":"0000000000000000000000000000000FC0FC000028000040000000000000780002100020400204003FC0000000000","type":"default","locked":true,"builtin":true,"default_id":"web_default_06"},{"name":"默认 08 三角眼委屈","hex":"00000000000000000000100200A014044088000000000000000005002829FE5004080010800090000600000000000","type":"default","locked":true,"builtin":true,"default_id":"web_default_07"},{"name":"默认 09 竖眼皱眉","hex":"000000000000000000001806006018018060060180000000000005002801FE0004080010800090000600000000000","type":"default","locked":true,"builtin":true,"default_id":"web_default_08"},{"name":"默认 10 X眼皱眉","hex":"00000000000000000000C000C0C00C0080400C00C0C000C0000005002829FE5004080010800090000600000000000","type":"default","locked":true,"builtin":true,"default_id":"web_default_09"},{"name":"默认 11 强强","hex":"0000000001C423A242451212208844042108108420000001084200000000FC0004080040200402004020040801F80","type":"default","locked":true,"builtin":true,"default_id":"web_default_10"}];
const ROW_LENS = [18,20,20,20,22,22,22,22,22,22,22,22,22,20,20,20,18,16];
const ROWS = 18;
const COLS = 22;
const PHY_BITS = ROW_LENS.reduce((a,b)=>a+b,0);
const PHY_HEX_LEN = Math.ceil(PHY_BITS / 4);
const LEGACY_ROW_OFFSET = 1;
const LEGACY_COL_OFFSET = 2;
const UNITY_FPS = 30;
const SAVE_KEY = 'rina_clean_saved_faces_v1';
const $ = id => document.getElementById(id);
const qa = sel => Array.from(document.querySelectorAll(sel));
function hardwareMode(){ return !!(window.rinaHardwareMode && window.rinaHardwareMode()); }
function previewMode(){ return !hardwareMode(); }
function toggleButtonValue(id){
  const el = $(id);
  if (!el) return false;
  if (el.tagName === 'INPUT' && el.type === 'checkbox') return !!el.checked;
  return el.getAttribute('aria-pressed') === 'true' || el.classList.contains('active') || el.dataset.checked === '1';
}
function setToggleButtonValue(id, on){
  const el = $(id);
  if (!el) return;
  const value = !!on;
  if (el.tagName === 'INPUT' && el.type === 'checkbox') {
    el.checked = value;
    return;
  }
  el.dataset.checked = value ? '1' : '0';
  el.setAttribute('aria-pressed', value ? 'true' : 'false');
  el.classList.toggle('active', value);
  if (id === 'saveFaceLocked') el.textContent = value ? '已锁定' : '锁定';
  else if (id === 'unityMediaLoop') el.textContent = value ? 'Loop 开' : 'Loop';
  else if (id === 'eyeSyncBox') el.textContent = value ? '左右眼同步：开' : '左右眼同步';
}
function bindToggleButton(id, initial, afterChange){
  const el = $(id);
  if (!el) return;
  setToggleButtonValue(id, toggleButtonValue(id) || !!initial);
  const eventName = (el.tagName === 'INPUT' && el.type === 'checkbox') ? 'change' : 'click';
  el.addEventListener(eventName, action(id + 'Toggle', function(){
    if (!(el.tagName === 'INPUT' && el.type === 'checkbox')) setToggleButtonValue(id, !toggleButtonValue(id));
    else setToggleButtonValue(id, !!el.checked);
    if (typeof afterChange === 'function') afterChange(toggleButtonValue(id));
  }));
}
function selectedSaveType(fallback){
  if (fallback === 'custom' || fallback === 'part') return fallback;
  const el = $('saveFaceType');
  return el && (el.value === 'custom' || el.value === 'part') ? el.value : 'custom';
}


let gridBits = Array(ROWS * COLS).fill(0);
let savedFaces = [];
let selectedFaceIndex = 0;
let statusTimer = null;
let mediaTimer = null;
let mediaElement = null;
let mediaBlobUrl = '';
let mediaToken = 0;
let mediaSilentFrame = 0;
let mediaLastFrame = 0;
let scrollPreviewTimer = null;
let scrollPreviewOffset = 0;

function log(msg){
  const box = $('log');
  const line = '[' + new Date().toLocaleTimeString() + '] ' + msg;
  if (box) box.textContent = line + '\n' + box.textContent.slice(0, 9000);
  try { console.log(line); } catch (_) {}
}
function debug(msg, data){
  const box = $('debugLog');
  const detail = data == null ? '' : ' ' + (typeof data === 'string' ? data : JSON.stringify(data));
  const line = '[' + new Date().toLocaleTimeString() + '] ' + msg + detail;
  if (box) box.textContent = line + '\n' + box.textContent.slice(0, 16000);
  try { console.debug(line); } catch (_) {}
}
const actionBusy = Object.create(null);
function action(label, fn){
  return function(ev){
    debug('button', label);
    if (actionBusy[label]) { debug('button ignored while busy', label); return undefined; }
    let result;
    try {
      result = fn.call(this, ev);
      if (result && typeof result.then === 'function') {
        actionBusy[label] = true;
        if (this && this.classList) this.classList.add('busy');
        return result.catch(error => {
          debug('action error: ' + label, error && (error.stack || error.message || String(error)));
          log(label + ' failed: ' + (error && error.message ? error.message : error));
        }).finally(() => {
          actionBusy[label] = false;
          if (this && this.classList) this.classList.remove('busy');
        });
      }
      return result;
    } catch (error) {
      actionBusy[label] = false;
      if (this && this.classList) this.classList.remove('busy');
      debug('action error: ' + label, error && (error.stack || error.message || String(error)));
      log(label + ' failed: ' + (error && error.message ? error.message : error));
      return undefined;
    }
  };
}
function on(id, event, label, fn){
  const el = $(id);
  if (!el) {
    debug('missing element', id);
    return null;
  }
  el.addEventListener(event, action(label || id, fn));
  return el;
}
function onAll(selector, event, label, fn){
  const nodes = qa(selector);
  if (!nodes.length) debug('missing selector', selector);
  nodes.forEach((el, index) => el.addEventListener(event, action((label || selector) + '#' + index, function(ev){ return fn.call(el, ev, el, index); })));
  return nodes;
}
window.addEventListener('error', ev => debug('window error', ev.message || String(ev.error || ev)));
window.addEventListener('unhandledrejection', ev => debug('promise rejection', ev.reason && (ev.reason.stack || ev.reason.message || String(ev.reason))));
function cleanHex(s){ return String(s || '').replace(/[^0-9a-fA-F]/g, '').toUpperCase(); }
function pad2(n){ return String(Math.max(0, Math.floor(n || 0))).padStart(2, '0'); }
function sleep(ms){ return new Promise(resolve => setTimeout(resolve, ms)); }
function rowPad(row){ return Math.floor((COLS - ROW_LENS[row]) / 2); }
function isRealCell(row, col){ const p = rowPad(row); return row >= 0 && row < ROWS && col >= p && col < p + ROW_LENS[row]; }
function realCells(){ const out=[]; for(let r=0;r<ROWS;r++) for(let c=0;c<COLS;c++) if(isRealCell(r,c)) out.push([r,c]); return out; }
function bitIndex(row, col){ return row * COLS + col; }
function toByte(n){ return Number(n || 0).toString(16).padStart(2, '0').toUpperCase(); }
function safeJson(text, fallback){ try { return JSON.parse(text); } catch (_) { return fallback; } }
function commandContentType(reply){ const s = String(reply || '').trim(); return s.charAt(0) === '{' || s.charAt(0) === '['; }
function localRequestReply(cmd){
  cmd = String(cmd || '');
  if (cmd === 'requestSavedFaces370') return JSON.stringify(localFaces().map(faceForFirmware));
  if (cmd === 'requestFace370') return 'M370:' + bitsToM370(gridBits);
  if (cmd === 'requestFace') return bitsToLegacyHex(gridBits);
  if (cmd === 'requestColor') return '#' + cleanHex(($('colorHex') && $('colorHex').value) || 'f971d4').slice(0, 6).padEnd(6, '0');
  if (cmd === 'requestBright') return String(parseInt(($('bright') && $('bright').value) || '16', 10) || 16);
  if (cmd === 'requestVersion') return 'local-preview';
  if (cmd === 'requestBattery') return JSON.stringify({percent:null, battery_voltage:null, charge_voltage:null, charging:false, remaining_minutes:null, charge_minutes:null, preview:true});
  if (cmd === 'requestManualMode' || cmd === 'requestControlMode') return JSON.stringify({manual_control_mode:false, control_mode:'preview', preview:true});
  if (cmd === 'requestEspStatus') return JSON.stringify({mode:'preview', ip:'local', version:'local-preview', runtime:{type:'preview'}});
  return 'preview ok';
}
function localApiText(path, opts){
  const method = (opts && opts.method) || 'GET';
  const url = new URL(String(path || '/'), 'http://local-preview');
  debug('preview api', method + ' ' + url.pathname);
  if (url.pathname === '/api/ping') return JSON.stringify({ok:true, message:'local preview', mode:'preview'});
  if (url.pathname === '/api/status') return JSON.stringify({mode:'preview', ip:'local', ap_ip:'', udp_port:0, rssi:0, manual_control_mode:false, control_mode:'preview', runtime:{type:'preview'}});
  if (url.pathname === '/api/faces') return JSON.stringify(localFaces().map(faceForFirmware));
  if (url.pathname === '/api/wifi/status') return JSON.stringify({mode:'preview', can_configure:false, sta_connected:false, sta_ssid:'', sta_ip:'', ap_active:false, ap_ip:'', rssi:0, sta_ssid_cfg:'', ap_ssid_cfg:'RinaChanBoard-S3'});
  if (url.pathname === '/api/wifi/scan') return JSON.stringify({ok:true, networks:[]});
  if (url.pathname === '/api/wifi/save') return JSON.stringify({ok:false, preview:true, message:'preview only'});
  if (url.pathname === '/api/request') return localRequestReply(url.searchParams.get('cmd') || '');
  if (url.pathname === '/api/send') {
    let msg = '';
    try {
      const body = opts && opts.body;
      const form = body instanceof URLSearchParams ? body : new URLSearchParams(String(body || ''));
      msg = form.get('msg') || form.get('plain') || '';
    } catch (_) {}
    return localRequestReply(msg);
  }
  if (url.pathname === '/api/binary') return cleanHex(url.searchParams.get('hex') || '') || 'preview ok';
  return 'preview ok';
}

async function apiText(path, opts){
  const fetchOpts = Object.assign({}, opts || {});
  const retries = Math.max(0, parseInt(fetchOpts.retries || '0', 10) || 0);
  delete fetchOpts.retries;
  const method = fetchOpts.method || 'GET';
  const target = (typeof window.rinaDeviceUrl === 'function') ? window.rinaDeviceUrl(path) : path;
  if (previewMode()) return localApiText(path, fetchOpts);
  debug('api request', method + ' ' + path + (target !== path ? ' -> ' + target : ''));
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      const r = await fetch(path, fetchOpts);
      const t = await r.text();
      debug('api response', method + ' ' + path + ' -> ' + r.status + ' ' + t.slice(0, 160));
      if (!r.ok) throw new Error(t || r.statusText);
      return t;
    } catch (error) {
      debug('api error', method + ' ' + path + ' ' + (error && error.message ? error.message : error));
      if (attempt >= retries) throw error;
      await sleep(150 * (attempt + 1));
      debug('api retry', method + ' ' + path + ' #' + (attempt + 2));
    }
  }
}
async function apiJson(path, opts){ const text = await apiText(path, opts); try { return JSON.parse(text); } catch (e) { throw new Error('JSON parse failed: ' + text.slice(0, 180)); } }
async function postForm(path, params, retries){
  return apiText(path, {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body:new URLSearchParams(params), cache:'no-store', retries: retries || 0});
}
async function sendText(msg, wait){
  const runtimeCommand = /^(scrollText|timeline370|runtimeStop)/.test(String(msg || ''));
  const t = await postForm('/api/send', {msg, wait: wait ? '1' : '0'}, runtimeCommand ? 2 : 0);
  const shown = String(msg || '').length > 180 ? String(msg).slice(0, 180) + '...' : String(msg || '');
  log((wait ? 'RX ' : 'TX ') + shown + (wait ? ' => ' + t : ''));
  return t;
}
async function sendHex(hex, wait, format){
  const t = await apiText('/api/binary?hex=' + encodeURIComponent(cleanHex(hex)) + '&wait=' + (wait ? '1' : '0') + '&format=' + encodeURIComponent(format || 'hex'));
  log((wait ? 'RX hex ' : 'TX hex ') + cleanHex(hex) + (wait ? ' => ' + t : ''));
  return t;
}
async function req(cmd){
  const t = await apiText('/api/request?cmd=' + encodeURIComponent(cmd));
  log(cmd + ' => ' + t);
  return t;
}

function bitsToM370(bits){
  let binary = '';
  for (const rc of realCells()) binary += bits[bitIndex(rc[0], rc[1])] ? '1' : '0';
  while (binary.length % 4) binary += '0';
  let out = '';
  for (let i=0; i<binary.length; i+=4) out += parseInt(binary.slice(i, i+4), 2).toString(16).toUpperCase();
  return out.slice(0, PHY_HEX_LEN);
}
function m370ToBits(hex){
  let raw = String(hex || '').trim();
  if (raw.toUpperCase().startsWith('M370:')) raw = raw.slice(5);
  let binary = '';
  for (const h of cleanHex(raw).padEnd(PHY_HEX_LEN, '0').slice(0, PHY_HEX_LEN)) binary += parseInt(h, 16).toString(2).padStart(4, '0');
  const bits = Array(ROWS * COLS).fill(0);
  let k = 0;
  for (const rc of realCells()) bits[bitIndex(rc[0], rc[1])] = binary[k++] === '1' ? 1 : 0;
  return bits;
}
function legacyHexToBits(hex){
  let binary = '';
  for (const h of cleanHex(hex).padEnd(72, '0').slice(0, 72)) binary += parseInt(h, 16).toString(2).padStart(4, '0');
  const bits = Array(ROWS * COLS).fill(0);
  for (let i=0; i<16*18; i++) {
    const r = Math.floor(i / 18) + LEGACY_ROW_OFFSET;
    const c = (i % 18) + LEGACY_COL_OFFSET;
    if (isRealCell(r, c)) bits[bitIndex(r, c)] = binary[i] === '1' ? 1 : 0;
  }
  return bits;
}
function bitsToLegacyHex(bits){
  let binary = '';
  for (let r=0; r<16; r++) for (let c=0; c<18; c++) {
    const rr = r + LEGACY_ROW_OFFSET, cc = c + LEGACY_COL_OFFSET;
    binary += isRealCell(rr, cc) && bits[bitIndex(rr, cc)] ? '1' : '0';
  }
  let out = '';
  for (let i=0; i<binary.length; i+=4) out += parseInt(binary.slice(i, i+4), 2).toString(16).toUpperCase();
  return out.padEnd(72, '0').slice(0, 72);
}
function bitmapToBits(bitmap){
  const bits = Array(ROWS * COLS).fill(0);
  (bitmap || []).forEach((row, r) => String(row || '').split('').forEach((ch, c) => {
    if (r < ROWS && c < COLS && isRealCell(r, c)) bits[bitIndex(r, c)] = ch === '#' || ch === '+' ? 1 : 0;
  }));
  return bits;
}
function bitsToBitmap(bits){
  const rows = [];
  for (let r=0; r<ROWS; r++) {
    let row = '';
    for (let c=0; c<COLS; c++) row += isRealCell(r,c) && bits[bitIndex(r,c)] ? '#' : '.';
    rows.push(row);
  }
  return rows;
}
function faceToBits(item){
  if (!item) return Array(ROWS * COLS).fill(0);
  if (item.hex) return m370ToBits(item.hex);
  return bitmapToBits(item.data || []);
}
function updateHexField(){ const el = $('faceHex'); if (el) el.value = 'M370:' + bitsToM370(gridBits); }
function setEditorBits(bits){ gridBits = bits.slice(0, ROWS * COLS); renderEditor(); updateHexField(); }
function bitmapTextToBits(text){
  const lines = [];
  String(text || '').split(/\r?\n/).forEach(function(raw){
    let line = String(raw || '').trim();
    const quoted = line.match(/[\"']([.#\+]{8,40})[\"']/);
    if (quoted) line = quoted[1];
    if (/^[.#\+]{8,40}$/.test(line)) lines.push(line);
  });
  if (!lines.length) return null;
  const bits = Array(ROWS * COLS).fill(0);
  for (let r=0; r<Math.min(ROWS, lines.length); r++) {
    const row = lines[r];
    for (let c=0; c<Math.min(COLS, row.length); c++) {
      if (isRealCell(r, c) && (row[c] === '#' || row[c] === '+')) bits[bitIndex(r,c)] = 1;
    }
  }
  return bits;
}
function setColorsByString(value){
  const bitmapBits = bitmapTextToBits(value);
  if (bitmapBits) { setEditorBits(bitmapBits); return; }
  setEditorBits(String(value || '').toUpperCase().startsWith('M370:') || cleanHex(value).length >= PHY_HEX_LEN ? m370ToBits(value) : legacyHexToBits(value));
}

function renderBits(container, bits, editable){
  if (!container) return;
  container.innerHTML = '';
  for (let r=0; r<ROWS; r++) for (let c=0; c<COLS; c++) {
    const real = isRealCell(r, c);
    const node = editable ? document.createElement('button') : document.createElement('span');
    node.className = (editable ? 'led ' : 'miniLed ') + (real ? '' : 'hidden ') + (c === Math.floor(COLS/2)-1 ? 'midCol ' : '') + (r === Math.floor(ROWS/2)-1 ? 'midRow ' : '') + (real && bits[bitIndex(r,c)] ? 'on' : '');
    if (real && editable) {
      node.type = 'button';
      node.title = 'row ' + r + ', col ' + c;
      node.addEventListener('pointerdown', ev => { ev.preventDefault(); gridBits[bitIndex(r,c)] = gridBits[bitIndex(r,c)] ? 0 : 1; renderEditor(); updateHexField(); });
      node.addEventListener('contextmenu', ev => { ev.preventDefault(); gridBits[bitIndex(r,c)] = 0; renderEditor(); updateHexField(); });
    }
    container.appendChild(node);
  }
}
function renderEditor(){ renderBits($('grid'), gridBits, true); }

function partSize(group){ return group === 'cheek' ? [5, 2] : [8, 8]; }
function getPart(group, idx){
  const faces = window.RINA_FACES || {};
  if (!idx) return group === 'cheek' ? faces.cheek00 : faces.none;
  return (faces[group] || [])[idx - 1] || faces.none;
}
function setPart(bits, bitmap, sr, sc, w, h, flip){
  for (let r=0; r<h; r++) for (let c=0; c<w; c++) {
    const srcC = flip ? w - 1 - c : c;
    const val = bitmap && bitmap[r] && bitmap[r][srcC];
    const rr = sr + r + LEGACY_ROW_OFFSET;
    const cc = sc + c + LEGACY_COL_OFFSET;
    if (isRealCell(rr, cc)) bits[bitIndex(rr, cc)] = val ? 1 : 0;
  }
}
function buildFaceBits(le, re, mo, ch){
  const bits = Array(ROWS * COLS).fill(0);
  setPart(bits, getPart('leye', le), 0, 0, 8, 8, false);
  setPart(bits, getPart('reye', re), 0, 10, 8, 8, false);
  setPart(bits, getPart('mouth', mo), 8, 5, 8, 8, false);
  setPart(bits, getPart('cheek', ch), 8, 0, 5, 2, false);
  setPart(bits, getPart('cheek', ch), 8, 13, 5, 2, true);
  return bits;
}
function faceFromSelectors(){
  const le = +$('leye').value || 0;
  const re = +$('reye').value || 0;
  const mo = +$('mouth').value || 0;
  const ch = +$('cheek').value || 0;
  setEditorBits(buildFaceBits(le, re, mo, ch));
  syncPartThumbSelection();
}
function makeOptions(select, count){
  if (!select) return;
  select.innerHTML = '';
  for (let i=0; i<=count; i++) {
    const o = document.createElement('option');
    o.value = String(i);
    o.textContent = i === 0 ? '00' : pad2(i);
    select.appendChild(o);
  }
}
function buildPartThumb(group, idx, selectId){
  const box = document.createElement('button');
  const size = partSize(group);
  const bmp = getPart(group, idx);
  box.type = 'button';
  box.className = 'partThumb';
  box.dataset.group = group;
  box.dataset.index = String(idx);
  const pixels = document.createElement('div');
  pixels.className = 'partPixels';
  pixels.style.gridTemplateColumns = 'repeat(' + size[0] + ',8px)';
  for (let r=0; r<size[1]; r++) for (let c=0; c<size[0]; c++) {
    const px = document.createElement('span');
    px.className = 'partPix ' + (bmp && bmp[r] && bmp[r][c] ? 'on' : '');
    pixels.appendChild(px);
  }
  const label = document.createElement('div');
  label.className = 'mono small';
  label.textContent = idx === 0 ? '00' : pad2(idx);
  box.appendChild(pixels);
  box.appendChild(label);
  box.addEventListener('click', () => {
    $(selectId).value = String(idx);
    if (selectId === 'leye' && toggleButtonValue('eyeSyncBox')) $('reye').value = String(idx);
    faceFromSelectors();
  });
  return box;
}
function renderPartGalleries(){
  const faces = window.RINA_FACES || {};
  [['leye','leyeGallery'],['reye','reyeGallery'],['mouth','mouthGallery'],['cheek','cheekGallery']].forEach(pair => {
    const group = pair[0], gallery = $(pair[1]);
    if (!gallery) return;
    gallery.innerHTML = '';
    const count = (faces[group] || []).length;
    for (let i=0; i<=count; i++) gallery.appendChild(buildPartThumb(group, i, group));
  });
  syncPartThumbSelection();
}
function syncPartThumbSelection(){
  const vals = {leye:+$('leye').value||0, reye:+$('reye').value||0, mouth:+$('mouth').value||0, cheek:+$('cheek').value||0};
  qa('.partThumb').forEach(el => el.classList.toggle('active', vals[el.dataset.group] === +el.dataset.index));
}
function randomizeParts(upload){
  const faces = window.RINA_FACES || {};
  const pick = group => Math.floor(Math.random() * ((faces[group] || []).length + 1));
  const le = pick('leye');
  $('leye').value = String(le);
  $('reye').value = String((toggleButtonValue('eyeSyncBox')) ? le : pick('reye'));
  $('mouth').value = String(pick('mouth'));
  $('cheek').value = String(pick('cheek'));
  faceFromSelectors();
  if (upload) uploadFace();
}

function normalizeFaceItem(item, index){
  const isDefault = item && (item.type === 'default' || item.builtin || item.default_id);
  const defaultRef = isDefault ? DEFAULT_FACES[index] : null;
  const bits = faceToBits(item);
  return {
    name: isDefault && defaultRef && defaultRef.name
      ? String(defaultRef.name)
      : (item && item.name ? String(item.name) : (isDefault ? '默认表情 ' + pad2(index + 1) : '自定义表情 ' + pad2(index + 1))),
    type: isDefault ? 'default' : ((item && item.type) || 'custom'),
    locked: !!(isDefault || (item && item.locked)),
    builtin: !!(item && item.builtin),
    default_id: item && item.default_id,
    data: bitsToBitmap(bits),
    hex: bitsToM370(bits)
  };
}
function displayFaceName(face, index){
  if (face && face.name) return face.name;
  if (face.type === 'default' || face.builtin || face.default_id) return '默认表情 ' + pad2(index + 1);
  return '自定义表情 ' + pad2(index + 1);
}
function localFaces(){
  const raw = safeJson(localStorage.getItem(SAVE_KEY) || '[]', []);
  return Array.isArray(raw) && raw.length ? raw.map(normalizeFaceItem) : DEFAULT_FACES.map(normalizeFaceItem);
}
function storeLocalFaces(list){ localStorage.setItem(SAVE_KEY, JSON.stringify(list.map(faceForFirmware))); }
function faceForFirmware(face){
  const out = {name: face.name, type: face.type || 'custom', locked: !!face.locked, data: face.data || bitsToBitmap(m370ToBits(face.hex))};
  if (face.default_id) out.default_id = face.default_id;
  if (face.builtin) out.builtin = true;
  return out;
}
async function loadFaces(){
  if (previewMode()) {
    savedFaces = localFaces();
    log('本地预览保存表情：' + savedFaces.length);
    selectedFaceIndex = Math.min(selectedFaceIndex, Math.max(0, savedFaces.length - 1));
    renderSavedFaces();
    return;
  }
  try {
    const list = await apiJson('/api/faces');
    savedFaces = (Array.isArray(list) ? list : []).map(normalizeFaceItem);
    storeLocalFaces(savedFaces);
    log('已从固件读取保存表情：' + savedFaces.length);
  } catch (error) {
    savedFaces = localFaces();
    log('使用本地保存表情：' + error.message);
  }
  selectedFaceIndex = Math.min(selectedFaceIndex, Math.max(0, savedFaces.length - 1));
  renderSavedFaces();
}
let dragSrcIdx = null;
function moveFace(from, to) {
  if (from === to || from < 0 || to < 0 || from >= savedFaces.length || to >= savedFaces.length) return;
  const item = savedFaces.splice(from, 1)[0];
  savedFaces.splice(to, 0, item);
  if (selectedFaceIndex === from) selectedFaceIndex = to;
  else if (from < selectedFaceIndex && to >= selectedFaceIndex) selectedFaceIndex--;
  else if (from > selectedFaceIndex && to <= selectedFaceIndex) selectedFaceIndex++;
  storeLocalFaces(savedFaces);
  renderSavedFaces();
  sendText('moveFace370|' + from + '|' + to, true).catch(function(e){ log('排序失败: ' + e.message); });
}
function renderSavedFaces(){
  const sel = $('savedFaces');
  const count = $('savedFacesCount');
  const list = $('savedFaceList');
  if (count) count.textContent = savedFaces.length + ' 个';
  if (sel) {
    sel.innerHTML = '';
    savedFaces.forEach(function(face, i){
      const o = document.createElement('option');
      o.value = String(i);
      const pfx = (face.type === 'default' || face.builtin) ? '*' : '';
      o.textContent = pfx + pad2(i + 1) + ' ' + displayFaceName(face, i) + ' [' + (face.type || 'custom') + ']';
      sel.appendChild(o);
    });
    sel.value = String(selectedFaceIndex);
  }
  if (list) {
    list.innerHTML = '';
    savedFaces.forEach(function(face, i){
      const isDef = face.type === 'default' || face.builtin;
      const row = document.createElement('div');
      row.className = 'faceRow' + (i === selectedFaceIndex ? ' active' : '');
      row.draggable = true;
      row.dataset.index = String(i);

      const num = document.createElement('div');
      num.className = 'num';
      num.textContent = (isDef ? '*' : '') + pad2(i + 1);

      const fname = document.createElement('div');
      fname.className = 'fname';
      fname.textContent = displayFaceName(face, i);
      fname.title = displayFaceName(face, i) + ' [' + (face.type || 'custom') + ']';

      const lockBtn = document.createElement('button');
      lockBtn.type = 'button';
      lockBtn.className = 'btn sm' + (face.locked ? ' warn' : '');
      lockBtn.textContent = face.locked ? '锁定' : '解锁';
      if (isDef) lockBtn.disabled = true;
      lockBtn.addEventListener('click', function(e){
        e.stopPropagation();
        selectedFaceIndex = i;
        toggleSelectedLock();
      });

      const typeBtn = document.createElement('button');
      typeBtn.type = 'button';
      typeBtn.className = 'btn sm';
      typeBtn.textContent = isDef ? '默认' : face.type === 'part' ? '部件' : '自定';
      if (isDef) typeBtn.disabled = true;
      typeBtn.addEventListener('click', function(e){
        e.stopPropagation();
        if (isDef) return;
        selectedFaceIndex = i;
        var newType = face.type === 'custom' ? 'part' : 'custom';
        face.type = newType;
        storeLocalFaces(savedFaces);
        renderSavedFaces();
        sendText('typeFace370|' + i + '|' + newType, true).catch(function(){ log('属性切换失败'); });
      });

      const delBtn = document.createElement('button');
      delBtn.type = 'button';
      delBtn.className = 'btn sm danger';
      delBtn.textContent = '删除';
      if (face.locked || isDef) delBtn.disabled = true;
      delBtn.addEventListener('click', function(e){
        e.stopPropagation();
        selectedFaceIndex = i;
        deleteSelectedFace();
      });

      const handle = document.createElement('div');
      handle.className = 'dragHandle';
      handle.textContent = '⋮';
      handle.title = '拖拽排序';

      row.addEventListener('click', function(){
        selectedFaceIndex = i;
        renderSavedFaces();
        previewSelectedFace();
        sendText('selectFace370|' + i, false).catch(function(e){ log('选择失败: ' + e.message); });
      });

      row.addEventListener('dragstart', function(e){
        dragSrcIdx = i;
        e.dataTransfer.effectAllowed = 'move';
        setTimeout(function(){ row.classList.add('dragging'); }, 0);
      });
      row.addEventListener('dragover', function(e){
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
        qa('.faceRow.drag-over').forEach(function(r){ r.classList.remove('drag-over'); });
        if (dragSrcIdx !== null && dragSrcIdx !== i) row.classList.add('drag-over');
      });
      row.addEventListener('dragleave', function(){ row.classList.remove('drag-over'); });
      row.addEventListener('drop', function(e){
        e.preventDefault();
        qa('.faceRow.drag-over').forEach(function(r){ r.classList.remove('drag-over'); });
        if (dragSrcIdx !== null && dragSrcIdx !== i) moveFace(dragSrcIdx, i);
        dragSrcIdx = null;
      });
      row.addEventListener('dragend', function(){
        qa('.faceRow.dragging').forEach(function(r){ r.classList.remove('dragging'); });
        qa('.faceRow.drag-over').forEach(function(r){ r.classList.remove('drag-over'); });
        dragSrcIdx = null;
      });

      var touchStartY = 0;
      handle.addEventListener('touchstart', function(e){
        dragSrcIdx = i;
        touchStartY = e.touches[0].clientY;
        row.classList.add('dragging');
        e.preventDefault();
      }, {passive: false});
      handle.addEventListener('touchmove', function(e){ e.preventDefault(); }, {passive: false});
      handle.addEventListener('touchend', function(e){
        row.classList.remove('dragging');
        qa('.faceRow.drag-over').forEach(function(r){ r.classList.remove('drag-over'); });
        if (dragSrcIdx === null) return;
        var touch = e.changedTouches[0];
        var el = document.elementFromPoint(touch.clientX, touch.clientY);
        var targetRow = el && el.closest('.faceRow');
        if (targetRow && targetRow.dataset.index != null) {
          var targetIdx = +targetRow.dataset.index;
          if (!isNaN(targetIdx) && targetIdx !== dragSrcIdx) moveFace(dragSrcIdx, targetIdx);
        }
        dragSrcIdx = null;
      });

      row.appendChild(num);
      row.appendChild(fname);
      row.appendChild(lockBtn);
      row.appendChild(typeBtn);
      row.appendChild(delBtn);
      row.appendChild(handle);
      list.appendChild(row);
    });
  }
  previewSelectedFace();
}
function previewSelectedFace(){
  const face = savedFaces[selectedFaceIndex];
  renderBits($('savedFacePreview'), faceToBits(face), false);
  const out = $('savedFaceOut');
  if (out && face) out.textContent = JSON.stringify({index:selectedFaceIndex, name:displayFaceName(face, selectedFaceIndex), type:face.type, locked:face.locked, hex:'M370:' + face.hex}, null, 2);
}
function loadSelectedFace(){
  const face = savedFaces[selectedFaceIndex];
  if (!face) return;
  setEditorBits(faceToBits(face));
  renderSavedFaces();
  sendText('selectFace370|' + selectedFaceIndex, false).catch(function(e){ log('载入表情失败: ' + e.message); });
}
async function addCurrentFace(typeOverride){
  const typ = selectedSaveType(typeOverride);
  const baseName = typ === 'part' ? '表情部件 ' : '自定义表情 ';
  const name = prompt('表情名称', baseName + pad2(savedFaces.length + 1));
  if (name == null) return;
  const item = {name: String(name).trim() || baseName.trim(), type: typ, locked: toggleButtonValue('saveFaceLocked'), data: bitsToBitmap(gridBits)};
  savedFaces.push(normalizeFaceItem(item, savedFaces.length));
  selectedFaceIndex = savedFaces.length - 1;
  storeLocalFaces(savedFaces);
  renderSavedFaces();
  try {
    await sendText('addFace370Json|' + JSON.stringify(item), true);
    await loadFaces();
  } catch (error) {
    log('保存到固件失败，仅保存到本地：' + error.message);
  }
}
async function saveCustomFaceToSharedStore(){
  const sel = $('saveFaceType');
  if (sel) sel.value = 'custom';
  return addCurrentFace('custom');
}
async function savePartFaceToSharedStore(){
  faceFromSelectors();
  const sel = $('saveFaceType');
  if (sel) sel.value = 'part';
  return addCurrentFace('part');
}
async function renameSelectedFace(){
  const face = savedFaces[selectedFaceIndex];
  if (!face || face.type === 'default' || face.builtin) return;
  const name = prompt('新的表情名称', face.name);
  if (name == null) return;
  face.name = String(name).trim() || face.name;
  storeLocalFaces(savedFaces);
  renderSavedFaces();
  try { await sendText('renameFace370Index|' + selectedFaceIndex + '|' + face.name, true); } catch (e) { log('固件重命名失败：' + e.message); }
}
async function toggleSelectedLock(){
  const face = savedFaces[selectedFaceIndex];
  if (!face || face.type === 'default' || face.builtin) return;
  face.locked = !face.locked;
  storeLocalFaces(savedFaces);
  renderSavedFaces();
  try { await sendText('lockFace370|' + selectedFaceIndex + '|' + (face.locked ? '1' : '0'), true); } catch (e) { log('固件锁定状态更新失败：' + e.message); }
}
async function deleteSelectedFace(){
  const face = savedFaces[selectedFaceIndex];
  if (!face || face.locked || face.type === 'default' || face.builtin) return;
  if (!confirm('删除 ' + displayFaceName(face, selectedFaceIndex) + ' ?')) return;
  const idx = selectedFaceIndex;
  savedFaces.splice(idx, 1);
  selectedFaceIndex = Math.max(0, Math.min(savedFaces.length - 1, idx));
  storeLocalFaces(savedFaces);
  renderSavedFaces();
  try { await sendText('deleteFace370Index|' + idx, true); await loadFaces(); } catch (e) { log('固件删除失败：' + e.message); }
}

function updateManualModeUi(enabled, raw){
  const badge = $('manualModeBadge');
  const btn = $('manualModeToggle');
  const out = $('manualModeOut');
  if (badge) { badge.textContent = enabled ? 'MANUAL / 手动控制中' : 'WEB / 网络控制中'; badge.className = 'pill ' + (enabled ? 'warn' : 'ok'); }
  if (btn) btn.textContent = enabled ? '停止手动控制模式' : '启动手动控制模式';
  if (out) out.textContent = typeof raw === 'string' ? raw : JSON.stringify(raw, null, 2);
}
async function requestManualMode(){
  const text = await req('requestManualMode');
  const obj = safeJson(text, null);
  updateManualModeUi(!!(obj && obj.manual_control_mode), text);
}
async function setManualMode(enabled){
  const text = await sendText('manualMode|' + (enabled ? '1' : '0'), true);
  updateManualModeUi(enabled, text);
}
async function toggleManualMode(){
  const badge = $('manualModeBadge');
  await setManualMode(!(badge && String(badge.textContent).includes('MANUAL')));
}

async function uploadFace(){ await sendText('M370:' + bitsToM370(gridBits), false); }
async function downloadFace(){
  try { setColorsByString(await req('requestFace370')); }
  catch (_) { setColorsByString(await req('requestFace')); }
}
async function uploadColor(){
  const hex = cleanHex($('colorHex').value).slice(0, 6).padEnd(6, '0');
  $('colorHex').value = hex.toLowerCase();
  $('colorPick').value = '#' + hex.toLowerCase();
  await sendText('#' + hex, false);
}
async function downloadColor(){
  const hex = cleanHex(await req('requestColor')).slice(0, 6).padEnd(6, '0');
  $('colorHex').value = hex.toLowerCase();
  $('colorPick').value = '#' + hex.toLowerCase();
}
async function uploadBright(){
  const b = Math.max(0, Math.min(255, parseInt($('bright').value || '0', 10) || 0));
  $('bright').value = String(b);
  await sendText('B' + String(b).padStart(3, '0'), false);
}
async function downloadBright(){ $('bright').value = String(parseInt(await req('requestBright'), 10) || 0); }
async function requestVersion(){ $('versionOut').textContent = await req('requestVersion'); }
async function requestEspStatus(){ $('espOut').textContent = await req('requestEspStatus'); }
async function updateStatus(){
  applyRunModeUi();
  try {
    const s = await apiJson('/api/status');
    $('status').textContent = 'mode=' + s.mode + ' ip=' + s.ip + ' ap=' + (s.ap_ip || '') + ' udp=' + s.udp_port + ' rssi=' + s.rssi;
    updateManualModeUi(!!s.manual_control_mode, s);
  } catch (error) {
    $('status').textContent = 'status error: ' + error.message;
  }
}
function updateBatteryUi(obj){
  const pct = obj.percent == null ? null : Math.max(0, Math.min(100, Number(obj.percent)));
  $('batteryBadge').textContent = pct == null ? '未知' : pct.toFixed(0) + '%';
  $('batteryBadge').className = 'pill ' + (obj.charging ? 'ok' : '');
  $('batteryBarFill').style.width = (pct == null ? 0 : pct) + '%';
  $('batteryPercent').textContent = pct == null ? '-' : pct.toFixed(1) + '%';
  $('batteryVoltage').textContent = obj.battery_voltage == null ? '-' : Number(obj.battery_voltage).toFixed(3) + ' V';
  $('batteryChargeVoltage').textContent = obj.charge_voltage == null ? '-' : Number(obj.charge_voltage).toFixed(3) + ' V';
  $('batteryCharging').textContent = obj.charging ? 'charging' : 'not charging';
  $('batteryRemaining').textContent = obj.remaining_minutes == null ? '-' : obj.remaining_minutes + ' min';
  $('batteryChargeTime').textContent = obj.charge_minutes == null ? '-' : obj.charge_minutes + ' min';
  $('batteryRaw').textContent = JSON.stringify(obj, null, 2);
}
async function requestBatteryJson(){
  const text = await req('requestBattery');
  updateBatteryUi(safeJson(text, {}));
}
async function autoSyncAll(){
  const out = $('espOut');
  const result = {};
  try { result.face370 = await req('requestFace370'); setColorsByString(result.face370); } catch(e) { result.face = e.message; }
  try { result.color = await req('requestColor'); } catch(e) { result.color = e.message; }
  try { result.bright = await req('requestBright'); } catch(e) { result.bright = e.message; }
  try { result.version = await req('requestVersion'); } catch(e) { result.version = e.message; }
  try { result.battery = safeJson(await req('requestBattery'), {}); updateBatteryUi(result.battery); } catch(e) { result.battery = e.message; }
  if (out) out.textContent = JSON.stringify(result, null, 2);
}

function glyphFor(ch){
  const db = window.RINA_UNITY_DB || {};
  const code = ch.charCodeAt(0);
  return (db.ascii || []).find(g => g.id === code || g.symbol === ch);
}
function textToBits(text, offset){
  const bits = Array(ROWS * COLS).fill(0);
  let x = COLS - (offset || 0);
  const y0 = 5;
  for (const ch of String(text || '')) {
    const g = glyphFor(ch) || glyphFor('?') || glyphFor(' ');
    const rows = g ? g.content : [];
    for (let r=0; r<7; r++) for (let c=0; c<5; c++) {
      const rr = y0 + r, cc = x + c;
      if (rows[r] && rows[r][c] && isRealCell(rr, cc)) bits[bitIndex(rr, cc)] = 1;
    }
    x += 6;
  }
  return bits;
}
function previewScrollText(){
  const text = String($('scrollText').value || '');
  renderBits($('scrollPreview'), textToBits(text, Math.max(0, COLS - 6)), false);
}
function stopLocalScrollPreview(){
  if (scrollPreviewTimer) {
    clearInterval(scrollPreviewTimer);
    scrollPreviewTimer = null;
  }
}
function startLocalScrollPreview(speed, text){
  stopLocalScrollPreview();
  scrollPreviewOffset = 0;
  const maxOffset = COLS + text.length * 6 + 8;
  const tick = function(){
    renderBits($('scrollPreview'), textToBits(text, scrollPreviewOffset), false);
    scrollPreviewOffset = (scrollPreviewOffset + 1) % Math.max(1, maxOffset);
  };
  tick();
  scrollPreviewTimer = setInterval(tick, speed);
}
async function startScrollText(){
  stopUnityMedia(false);
  const speed = Math.max(40, Math.min(1000, parseInt($('scrollSpeed').value || '120', 10) || 120));
  const text = String($('scrollText').value || '').replace(/[\r\n\t|]/g, ' ').slice(0, 96);
  previewScrollText();
  if (previewMode()) {
    startLocalScrollPreview(speed, text);
    log('滚动文字本地预览：' + text);
    return;
  }
  await sendText('scrollText370|' + speed + '|' + text, true);
}
async function stopScrollText(doFirmwareStop){
  stopLocalScrollPreview();
  if (hardwareMode() && doFirmwareStop !== false) await sendText('scrollTextStop370', true);
}

function db(){ return window.RINA_UNITY_DB || {}; }
function timelineOf(kind, key){
  const d = db();
  if (kind === 'voice') return (d.voiceTimelines || {})[key] || [];
  if (kind === 'music') return (d.musicTimelines || {})[key] || [];
  return (d.videoTimelines || {})[key] || [];
}
function mediaKeys(kind){
  const d = db();
  const map = kind === 'voice' ? d.voiceTimelines : kind === 'music' ? d.musicTimelines : d.videoTimelines;
  return Object.keys(map || {});
}
function mediaAsset(kind, key, index){
  const d = db();
  if (kind === 'voice') {
    const number = parseInt(String(key).replace(/^\D+/, ''), 10);
    return (d.voiceDb || []).find(item => Number(item.id) === number)
      || (window.RINA_VOICE_DATA || [])[index]
      || null;
  }
  if (kind === 'music') {
    return (d.musicDb || []).find(item => item.cover === key)
      || (window.RINA_MUSIC_DATA || []).find(item => item.cover === key || item.id === key)
      || null;
  }
  return (d.videoDb || []).find(item => item.cover === key || String(item.id) === String(key)) || null;
}
function mediaLabel(kind, key, index){
  const item = mediaAsset(kind, key, index);
  if (!item) return key;
  if (kind === 'voice') return key + ' - ' + (item.content || item.text || item.id || '');
  if (kind === 'music') return key + ' - ' + (item.title || item.name || item.id || '') + (item.artist || item.singer ? ' / ' + (item.artist || item.singer) : '');
  return key + ' - ' + (item.title || item.name || item.id || '');
}
function drawUnityModule(bits, key, sr, sc, h, w, flip){
  const mods = (db().faceModules || {});
  const bmp = mods[String(key)] || mods[key] || mods['0'];
  if (!bmp) return;
  for (let y=0; y<h; y++) for (let x=0; x<w; x++) {
    const sx = flip ? w - 1 - x : x;
    const rr = sr + y + LEGACY_ROW_OFFSET, cc = sc + x + LEGACY_COL_OFFSET;
    if (bmp[y] && bmp[y][sx] && isRealCell(rr, cc)) bits[bitIndex(rr, cc)] = 1;
  }
}
function unityFaceToBits(face){
  const bits = Array(ROWS * COLS).fill(0);
  face = face || {};
  drawUnityModule(bits, face.leye, 0, 0, 8, 8, false);
  drawUnityModule(bits, face.reye, 0, 10, 8, 8, false);
  drawUnityModule(bits, face.mouth, 8, 5, 8, 8, false);
  drawUnityModule(bits, face.cheek, 8, 14, 4, 4, false);
  drawUnityModule(bits, face.cheek, 8, 0, 4, 4, true);
  return bits;
}
function findTimelineIndex(tl, frame){ let best = -1; for (let i=0; i<tl.length; i++) { if ((tl[i].frame || 0) <= frame) best = i; else break; } return best; }
function currentMedia(){
  const kindEl = $('unityMediaKind');
  const selectEl = $('unityMediaSelect');
  const kind = kindEl ? (kindEl.value || 'voice') : 'voice';
  const key = selectEl ? (selectEl.value || '') : '';
  return {kind, key, timeline: timelineOf(kind, key)};
}
function updateMediaSelect(){
  const kindEl = $('unityMediaKind');
  const sel = $('unityMediaSelect');
  if (!kindEl || !sel) {
    debug('media select skipped', 'missing unityMediaKind or unityMediaSelect');
    return;
  }
  const kind = kindEl.value || 'voice';
  sel.innerHTML = '';
  mediaKeys(kind).forEach((key, index) => {
    const o = document.createElement('option');
    o.value = key;
    o.textContent = mediaLabel(kind, key, index);
    sel.appendChild(o);
  });
  chooseUnityMedia(false);
}
function applyUnityFrame(frame, send){
  const cur = currentMedia();
  const idx = findTimelineIndex(cur.timeline, frame || 0);
  if (idx < 0) { log('Unity 没有可预览帧'); return null; }
  const bits = unityFaceToBits(cur.timeline[idx].face);
  renderBits($('unityMediaPreview'), bits, false);
  const hx = bitsToM370(bits);
  if (send && hardwareMode() && typeof window.sendText === 'function') sendText('M370:' + hx, false).catch(e => log('preview send failed: ' + e.message));
  const last = cur.timeline.length ? cur.timeline[cur.timeline.length - 1].frame || 0 : 0;
  if ($('unityMediaTime')) $('unityMediaTime').textContent = Math.floor((frame || 0) / UNITY_FPS) + 's / ' + Math.floor(last / UNITY_FPS) + 's';
  return hx;
}
function chooseUnityMedia(send){
  stopUnityMedia(false);
  const cur = currentMedia();
  const firstFrame = (cur.timeline && cur.timeline.length) ? (cur.timeline[0].frame || 0) : 0;
  const hx = applyUnityFrame(firstFrame, send !== false);
  log('Unity 预览：' + cur.kind + ':' + cur.key + ' frame=' + firstFrame + (hx ? ' hex=' + hx.slice(0, 16) + '...' : ''));
  const selected = $('unityMediaSelect') ? $('unityMediaSelect').selectedIndex : 0;
  const infoEl = $('unityMediaInfo');
  if (infoEl) infoEl.textContent = JSON.stringify({
    kind: cur.kind,
    key: cur.key,
    label: mediaLabel(cur.kind, cur.key, selected),
    asset: mediaAsset(cur.kind, cur.key, selected),
    frames: cur.timeline.length
  }, null, 2);
}
function sourceAssetPath(kind, key, item){
  item = item || {};
  if (item.music_src) return item.music_src;
  if (item.video_src) return item.video_src;
  if (item.audio_src) return item.audio_src;
  if (item.src) return item.src;
  if (item.url) return item.url;
  if (kind === 'music' && key) return '/assets/music/music_' + encodeURIComponent(key) + '.ogg';
  if (kind === 'video' && key) return '/assets/video/video_' + encodeURIComponent(key) + '.mp4';
  if (kind === 'voice') {
    const n = String(key || '').match(/(\d+)/);
    if (n) return '/assets/voice/voice_' + n[1] + '.ogg';
  }
  return '';
}
function mediaSource(){
  if (previewMode()) return '';
  const cur = currentMedia();
  const selected = $('unityMediaSelect') ? $('unityMediaSelect').selectedIndex : 0;
  const src = sourceAssetPath(cur.kind, cur.key, mediaAsset(cur.kind, cur.key, selected));
  return (src && src.charAt(0) === '/' && typeof window.rinaDeviceUrl === 'function') ? window.rinaDeviceUrl(src) : src;
}
function showMediaElement(kind, url){
  const audio = $('unityMediaAudio'), video = $('unityMediaVideo');
  if (audio) { audio.pause(); audio.style.display = 'none'; }
  if (video) { video.pause(); video.style.display = 'none'; }
  if (!url) return null;
  const el = kind === 'video' ? video : audio;
  if (!el) return null;
  el.src = url;
  el.style.display = 'block';
  try { el.currentTime = 0; el.play().catch(()=>{}); } catch (_) {}
  return el;
}
function buildFirmwareTimeline(cur){
  const entries = [];
  let lastHex = '';
  for (const row of cur.timeline) {
    const hx = bitsToM370(unityFaceToBits(row.face));
    if (hx !== lastHex) { entries.push({frame: row.frame || 0, hex: hx}); lastHex = hx; }
  }
  if (entries.length && entries[0].frame > 0) entries.unshift({frame: 0, hex: entries[0].hex});
  const last = cur.timeline.length ? cur.timeline[cur.timeline.length - 1].frame || 0 : 0;
  const name = (cur.kind + ':' + cur.key).replace(/[|;,\r\n]/g, ' ').slice(0, 48);
  return {entries, last, name, loaded: entries.length};
}
async function sendFirmwareTimeline(cur, loop){
  const plan = buildFirmwareTimeline(cur);
  const entries = plan.entries;
  const last = plan.last;
  const name = plan.name;
  await sendText('timeline370Clear', true);
  await sendText('timeline370Begin|' + UNITY_FPS + '|' + last + '|' + (loop ? '1' : '0') + '|' + entries.length + '|' + name, true);
  let chunk = '';
  let loaded = 0;
  for (const e of entries) {
    const part = String(e.frame) + ',' + e.hex + ';';
    if ((chunk + part).length > 640) {
      const reply = await sendText('timeline370Chunk|' + chunk, true);
      const info = safeJson(reply, {});
      if (info && info.loaded != null) loaded = Number(info.loaded) || loaded;
      chunk = '';
    }
    chunk += part;
  }
  if (chunk) {
    const reply = await sendText('timeline370Chunk|' + chunk, true);
    const info = safeJson(reply, {});
    if (info && info.loaded != null) loaded = Number(info.loaded) || loaded;
  }
  if (loaded && loaded < entries.length) throw new Error('时间轴上传不完整：' + loaded + '/' + entries.length);
  return {entries, last, name, loaded: loaded || entries.length};
}
function stopUnityMedia(doFirmwareStop){
  if (mediaTimer) { clearInterval(mediaTimer); mediaTimer = null; }
  if (mediaElement) { try { mediaElement.pause(); } catch (_) {} }
  if (mediaBlobUrl && mediaBlobUrl.startsWith('blob:')) { try { URL.revokeObjectURL(mediaBlobUrl); } catch (_) {} }
  mediaElement = null; mediaBlobUrl = ''; mediaSilentFrame = 0; mediaLastFrame = 0; mediaToken++;
  if (hardwareMode() && doFirmwareStop !== false) sendText('runtimeStop|media', false).catch(e => log('停止媒体失败：' + e.message));
}
async function playUnityMedia(){
  const cur = currentMedia();
  if (!cur.timeline.length) { alert('没有时间轴数据'); return; }
  stopUnityMedia(false);
  const loop = toggleButtonValue('unityMediaLoop');
  const sent = previewMode() ? buildFirmwareTimeline(cur) : await sendFirmwareTimeline(cur, loop);
  mediaBlobUrl = mediaSource();
  mediaElement = showMediaElement(cur.kind, mediaBlobUrl);
  mediaLastFrame = sent.last;
  const token = ++mediaToken;
  if (hardwareMode()) await sendText('timeline370Play', true);
  mediaTimer = setInterval(() => {
    if (token !== mediaToken) return;
    let frame = mediaElement && mediaBlobUrl && !mediaElement.paused ? Math.floor((mediaElement.currentTime || 0) * UNITY_FPS) : mediaSilentFrame++;
    if (frame > mediaLastFrame + 20 || (mediaElement && mediaBlobUrl && mediaElement.ended)) {
      if (loop) { mediaSilentFrame = 0; if (mediaElement && mediaBlobUrl) { try { mediaElement.currentTime = 0; mediaElement.play(); } catch (_) {} } frame = 0; }
      else { stopUnityMedia(true); return; }
    }
    applyUnityFrame(frame, false);
  }, Math.max(20, Math.floor(1000 / UNITY_FPS)));
  log((previewMode() ? 'Unity 本地预览：' : 'Unity 时间轴已发送：') + sent.loaded + '/' + sent.entries.length + ' keyframes, ' + sent.name);
}

async function sendFaceLiteBinary(){ await sendHex([+$('leye').value, +$('reye').value, +$('mouth').value, +$('cheek').value].map(toByte).join(''), false); }
async function sendTextLite(){ const h = cleanHex($('textLiteHex').value).padEnd(32, '0').slice(0, 32); $('textLiteHex').value = h; await sendHex(h, false); }
async function sendFaceFullBinary(){ await sendHex(bitsToLegacyHex(gridBits), false); }
async function binaryRequest(value){
  const parts = String(value).split(':');
  $('binaryOut').textContent = await sendHex(parts[0], true, parts[1] || 'hex');
}

let wifiCanConfigure = false;
function applyWifiLock(){
  const readonly = !wifiCanConfigure;
  ['wifiSsid','wifiPassword','wifiApSsid','wifiApPassword','wifiApChannel','wifiSaveBtn','wifiApSaveBtn','wifiScanBtn'].forEach(id => { const el = $(id); if (el) el.disabled = readonly; });
  if ($('wifiReadonlyBanner')) $('wifiReadonlyBanner').style.display = readonly ? '' : 'none';
  if ($('wifiApReadonlyBanner')) $('wifiApReadonlyBanner').style.display = readonly ? '' : 'none';
}
async function wifiRefreshStatus(){
  const out = $('wifiStatusOut');
  out.textContent = '读取中...';
  try {
    const s = await apiJson('/api/wifi/status');
    wifiCanConfigure = !!s.can_configure;
    out.textContent = (s.sta_connected ? 'STA: 已连接 SSID=' + s.sta_ssid + ' IP=' + s.sta_ip : 'STA: 未连接') + '\nAP: ' + (s.ap_ssid_cfg || s.ap_ssid || 'RinaChanBoard-S3') + ' IP=' + (s.ap_ip || '192.168.4.1');
    $('wifiModeNote').textContent = wifiCanConfigure ? '设备 AP 已开启，可扫描并修改 Wi-Fi。' : '当前 Wi-Fi 配置只读。';
    if (s.sta_ssid_cfg && !$('wifiSsid').value) $('wifiSsid').value = s.sta_ssid_cfg;
    if (s.ap_ssid_cfg && !$('wifiApSsid').value) $('wifiApSsid').value = s.ap_ssid_cfg;
    applyWifiLock();
  } catch (error) {
    out.textContent = '读取失败：' + error.message;
  }
}
async function wifiScan(){
  const box = $('wifiScanResults'), btn = $('wifiScanBtn');
  btn.disabled = true; btn.textContent = '扫描中...'; box.style.display = 'block'; box.textContent = '扫描中...';
  try {
    const data = await apiJson('/api/wifi/scan?t=' + Date.now());
    const nets = data.networks || [];
    const err = nets.find(n => n && n.error);
    if (err) throw new Error(err.error);
    box.innerHTML = nets.length ? '' : '<span class="small">未发现网络</span>';
    nets.forEach(n => {
      const row = document.createElement('button');
      row.type = 'button'; row.className = 'btn'; row.style.margin = '2px'; row.textContent = n.ssid + '  ' + n.rssi + ' dBm' + (n.channel ? '  ch' + n.channel : '');
      row.addEventListener('click', () => { $('wifiSsid').value = n.ssid; box.style.display = 'none'; $('wifiPassword').focus(); });
      box.appendChild(row);
    });
  } catch (error) { box.textContent = '扫描失败：' + error.message; }
  btn.disabled = false; btn.textContent = '扫描';
}
async function wifiSave(){
  if (!wifiCanConfigure) { alert('只能在连接到设备 AP 热点时修改 Wi-Fi。'); return; }
  const body = {
    ssid: $('wifiSsid').value.trim(),
    password: $('wifiPassword').value || '',
    ap_ssid: $('wifiApSsid').value.trim() || 'RinaChanBoard-S3',
    ap_password: $('wifiApPassword').value || '',
    ap_channel: $('wifiApChannel').value || '6'
  };
  try {
    const data = await apiJson('/api/wifi/save', {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body:new URLSearchParams(body)});
    $('wifiSaveOut').textContent = JSON.stringify(data, null, 2);
  } catch (error) { $('wifiSaveOut').textContent = '保存失败：' + error.message; }
}
function wifiTogglePw(){
  const pw = $('wifiPassword'), btn = $('wifiPwToggle');
  pw.type = pw.type === 'password' ? 'text' : 'password';
  btn.textContent = pw.type === 'password' ? '显示' : '隐藏';
}

function currentRunMode(){
  return hardwareMode() ? 'device' : 'preview';
}
function applyRunModeUi(){
  const mode = currentRunMode();
  const hostEl = $('host');
  if (hostEl) hostEl.textContent = location.host || 'local file';
  const badge = $('runModeBadge');
  if (badge) {
    badge.textContent = mode === 'device' ? 'DEVICE / 设备控制' : 'PREVIEW / 本地预览';
    badge.className = 'pill ' + (mode === 'device' ? 'ok' : 'warn');
  }
  const out = $('runModeOut');
  if (out) out.textContent = JSON.stringify({mode, host: location.host || 'local file', api: hardwareMode() ? location.origin : null}, null, 2);
  const play = $('playUnityMedia');
  if (play) play.textContent = hardwareMode() ? '发送并播放' : '预览播放';
}

function fillSelectors(){
  const faces = window.RINA_FACES || {};
  makeOptions($('leye'), (faces.leye || []).length);
  makeOptions($('reye'), (faces.reye || []).length);
  makeOptions($('mouth'), (faces.mouth || []).length);
  makeOptions($('cheek'), (faces.cheek || []).length);
  const colors = $('presetColor');
  if (colors) {
    colors.innerHTML = '';
    (window.RINA_COLOR_INFO || []).forEach((c, i) => {
      const o = document.createElement('option');
      o.value = c.color; o.textContent = pad2(i) + ' ' + c.name + ' #' + c.color;
      colors.appendChild(o);
    });
  }
  const ch = $('wifiApChannel');
  if (ch) for (let i=1; i<=13; i++) { const o = document.createElement('option'); o.value = String(i); o.textContent = String(i); if (i === 6) o.selected = true; ch.appendChild(o); }
  updateMediaSelect();
}
function bind(){
  bindToggleButton('saveFaceLocked', false);
  bindToggleButton('unityMediaLoop', false);
  bindToggleButton('eyeSyncBox', false, function(on){ if (on && $('leye') && $('reye')) $('reye').value = $('leye').value; faceFromSelectors(); });
  applyRunModeUi();
  on('clearDebugLog', 'click', 'clearDebugLog', () => { const box = $('debugLog'); if (box) box.textContent = ''; });
  onAll('[data-tab]', 'click', 'tab', (ev, btn) => {
    qa('[data-tab]').forEach(b => b.classList.remove('active'));
    qa('.tab').forEach(t => t.classList.remove('show'));
    btn.classList.add('active'); $(btn.dataset.tab).classList.add('show');
    if (hardwareMode()) sendText('runtimeStop|tabSwitch', false).catch(function(){});
    if (btn.dataset.tab === 'tab-wifi') wifiRefreshStatus();
    if (btn.dataset.tab === 'tab-saved') loadFaces();
  });
  on('refreshStatus', 'click', 'refreshStatus', updateStatus);
  on('readVersion', 'click', 'readVersion', requestVersion);
  on('readEspStatus', 'click', 'readEspStatus', requestEspStatus);
  on('manualModeToggle', 'click', 'manualModeToggle', toggleManualMode);
  on('manualModeRefresh', 'click', 'manualModeRefresh', requestManualMode);
  on('colorPick', 'input', 'colorPick', () => { $('colorHex').value = $('colorPick').value.slice(1); });
  on('usePresetColor', 'click', 'usePresetColor', () => { $('colorHex').value = $('presetColor').value; $('colorPick').value = '#' + $('presetColor').value; return uploadColor(); });
  on('uploadColor', 'click', 'uploadColor', uploadColor);
  on('downloadColor', 'click', 'downloadColor', downloadColor);
  on('uploadBright', 'click', 'uploadBright', uploadBright);
  on('downloadBright', 'click', 'downloadBright', downloadBright);
  onAll('[data-bright]', 'click', 'brightPreset', (ev, btn) => { $('bright').value = btn.dataset.bright; return uploadBright(); });
  on('readBattery', 'click', 'readBattery', requestBatteryJson);
  on('autoSync', 'click', 'autoSync', autoSyncAll);
  on('clearFace', 'click', 'clearFace', () => setEditorBits(Array(ROWS * COLS).fill(0)));
  on('invertFace', 'click', 'invertFace', () => setEditorBits(gridBits.map((b, i) => isRealCell(Math.floor(i / COLS), i % COLS) ? (b ? 0 : 1) : 0)));
  on('uploadFace', 'click', 'uploadFace', uploadFace);
  on('downloadFace', 'click', 'downloadFace', downloadFace);
  on('loadHexToEditor', 'click', 'loadHexToEditor', () => setColorsByString($('faceHex').value));
  on('sendLegacyBinary', 'click', 'sendLegacyBinary', sendFaceFullBinary);
  on('saveCustomFace', 'click', 'saveCustomFace', saveCustomFaceToSharedStore);
  ['leye','reye','mouth','cheek'].forEach(id => on(id, 'change', id + 'Change', () => { if (id === 'leye' && toggleButtonValue('eyeSyncBox') && $('reye')) $('reye').value = $('leye').value; faceFromSelectors(); }));
  on('buildFace', 'click', 'buildFace', faceFromSelectors);
  on('uploadPartFace', 'click', 'uploadPartFace', () => { faceFromSelectors(); return uploadFace(); });
  on('randomPartBtn', 'click', 'randomPart', () => randomizeParts(false));
  on('randomUploadPartBtn', 'click', 'randomUploadPart', () => randomizeParts(true));
  on('sendFaceLiteBinary', 'click', 'sendFaceLiteBinary', sendFaceLiteBinary);
  on('savePartFace', 'click', 'savePartFace', savePartFaceToSharedStore);
  on('reloadFaces', 'click', 'reloadFaces', loadFaces);
  on('saveCurrentFace', 'click', 'saveCurrentFace', addCurrentFace);
  on('savedFaces', 'change', 'savedFacesChange', () => { selectedFaceIndex = +$('savedFaces').value || 0; renderSavedFaces(); sendText('selectFace370|' + selectedFaceIndex, false).catch(function(){}); });
  on('loadCustomFace', 'click', 'loadCustomFace', loadSelectedFace);
  on('renameCustomFace', 'click', 'renameCustomFace', renameSelectedFace);
  on('toggleLockFace', 'click', 'toggleLockFace', toggleSelectedLock);
  on('deleteCustomFace', 'click', 'deleteCustomFace', deleteSelectedFace);
  on('previewScrollText', 'click', 'previewScrollText', previewScrollText);
  on('startScrollText', 'click', 'startScrollText', startScrollText);
  on('stopScrollText', 'click', 'stopScrollText', () => stopScrollText(true));
  on('unityMediaKind', 'change', 'unityMediaKind', updateMediaSelect);
  on('chooseUnityMedia', 'click', 'chooseUnityMedia', () => chooseUnityMedia(true));
  on('playUnityMedia', 'click', 'playUnityMedia', playUnityMedia);
  on('stopUnityMedia', 'click', 'stopUnityMedia', () => stopUnityMedia(true));
  onAll('[data-binary-request]', 'click', 'binaryRequest', (ev, btn) => binaryRequest(btn.dataset.binaryRequest));
  on('sendTextLite', 'click', 'sendTextLite', sendTextLite);
  on('sendRawHex', 'click', 'sendRawHex', () => sendHex($('rawHex').value, false));
  on('sendRawHexWait', 'click', 'sendRawHexWait', () => sendHex($('rawHex').value, true));
  on('wifiRefreshStatus', 'click', 'wifiRefreshStatus', wifiRefreshStatus);
  on('wifiScanBtn', 'click', 'wifiScan', wifiScan);
  on('wifiSaveBtn', 'click', 'wifiSave', wifiSave);
  on('wifiApSaveBtn', 'click', 'wifiApSave', wifiSave);
  on('wifiPwToggle', 'click', 'wifiTogglePw', wifiTogglePw);
}
function init(){
  fillSelectors();
  bind();
  renderEditor();
  renderPartGalleries();
  previewScrollText();
  $('dbInfo').textContent = JSON.stringify({
    ascii: (db().ascii || []).length,
    faceModules: Object.keys(db().faceModules || {}).length,
    voiceTimelines: Object.keys(db().voiceTimelines || {}).length,
    musicTimelines: Object.keys(db().musicTimelines || {}).length,
    videoTimelines: Object.keys(db().videoTimelines || {}).length
  }, null, 2);
  loadFaces();
  updateStatus();
  statusTimer = setInterval(updateStatus, 5000);
  requestManualMode().catch(()=>{});
  log('Web UI ready');
}

Object.assign(window, {
  sendText, sendHex, req, log, debug, setColorsByString, clearFace: () => setEditorBits(Array(ROWS * COLS).fill(0)),
  invertFace: () => setEditorBits(gridBits.map((b, i) => isRealCell(Math.floor(i / COLS), i % COLS) ? (b ? 0 : 1) : 0)),
  uploadFace, downloadFace, uploadColor, downloadColor, uploadBright, downloadBright, requestVersion,
  requestEspStatus, requestBatteryJson, autoSyncAll, faceFromSelectors, sendFaceLiteBinary,
  sendTextLite, sendFaceFullBinary, saveCustomFaceToSharedStore, savePartFaceToSharedStore, startScrollText, stopScrollText, previewScrollText,
  chooseUnityMedia, playUnityMedia, stopUnityMedia, wifiRefreshStatus, wifiScan, wifiSave, wifiTogglePw,
  requestManualMode, setManualMode, toggleManualMode
});

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, {once:true});
else init();
})();
// APP_RUNTIME_END
