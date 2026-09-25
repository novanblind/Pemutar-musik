require "import"
import "android.app.*"
import "android.content.*"
import "android.widget.*"
import "android.view.*"
import "android.os.*"
import "android.net.Uri"
import "android.provider.MediaStore"
import "android.media.MediaPlayer"
import "android.media.PlaybackParams"
import "android.media.AudioManager"
import "android.media.audiofx.Equalizer"
import "android.media.audiofx.BassBoost"
import "android.media.audiofx.PresetReverb"
import "java.io.*"
import "java.net.URL"
import "java.net.HttpURLConnection"
import "java.lang.Thread"
import "java.lang.Runnable"
import "java.lang.reflect.Array"
import "java.lang.System"
import "android.content.ClipData"

local APP_VERSION = "1.0.13"
local UPDATE_URL = "https://raw.githubusercontent.com/novanblind/Pemutar-musik/main/Musicplayer.lua"

local mainHandler = Handler(Looper.getMainLooper())
local PREFS_NAME = "novan_folder_audio_player_prefs_secure"
local prefs = service.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
local sysProps = System.getProperties()
local audioManager = service.getSystemService(Context.AUDIO_SERVICE)

-- Variabel Status Pemutar Media
local mediaPlayer = sysProps.get("GLOBAL_ADV_MEDIA_PLAYER")
local nextMediaPlayer = nil -- Pemutar cadangan untuk mode Gapless murni & siaga Crossfade instan
local fadingOldPlayers = {} -- Penampung aman pemutar lama yang sedang fade-out agar tidak bocor memori
local isCrossfading = false -- Penanda proses pudar silang sedang berlangsung
local songList = {}
local filteredSongs = {}
local folderList = {}
local currentFolderPath = prefs.getString("last_folder_path", "")
local currentFolderName = prefs.getString("last_folder_name", "Semua Lagu")
local currentIndex = tonumber(sysProps.get("GLOBAL_ADV_SONG_INDEX") or "-1")
local currentSongPath = tostring(sysProps.get("GLOBAL_ADV_SONG_PATH") or "")
local isPlaying = false
local isLoopingAB = false
local loopA = 0
local loopB = 0
-- Daftar kecepatan putar bersama
local SPEED_LABELS = {"0.5x", "0.75x", "1.0x (Normal)", "1.25x", "1.5x", "2.0x"}
local SPEED_VALUES = {0.5, 0.75, 1.0, 1.25, 1.5, 2.0}
local currentPitch = prefs.getFloat("pref_pitch_value", 1.0)
local currentSpeed = SPEED_VALUES[(prefs.getInt("pref_speed", 2)) + 1] or 1.0
local sleepTimerRunnable = nil
local isSleepTimerArmed = false
local isUserSeeking = false
local mainDialog = nil
local isServiceRunning = true -- Menjaga siklus transisi dan ducking tetap aktif di latar belakang

-- Status Ducking (Peredam Audio)
local isFocusDucked = false
local isRecordingDucked = false

-- Status Efek Audio (Equalizer, Bass Boost, Echo)
local audioEqualizer = nil
local audioBassBoost = nil
local audioReverb = nil

-- Format Milidetik ke MM:SS
local function formatTime(ms)
  if not ms or ms < 0 then return "0:00" end
  local totalSec = math.floor(ms / 1000)
  local m = math.floor(totalSec / 60)
  local s = totalSec % 60
  return string.format("%d:%02d", m, s)
end

-- Ambil batas volume maksimal saat ini (memperhitungkan Ducking)
local function getCurrentMaxVolume()
  local isDuckingEnabled = (prefs.getInt("pref_ducking", 0) == 1)
  if isDuckingEnabled and (isFocusDucked or isRecordingDucked) then
    return 0.2
  end
  return 1.0
end

-- ============================================================================
-- PENGATUR VOLUME OTOMATIS (DUCKING SAAT BICARA & REKAM)
-- ============================================================================
local function applyVolumeDucking()
  pcall(function()
    if not mediaPlayer or isCrossfading then return end
    local maxV = getCurrentMaxVolume()
    mediaPlayer.setVolume(maxV, maxV)
  end)
end

local audioFocusListener = nil
pcall(function()
  audioFocusListener = luajava.bindClass("android.media.AudioManager$OnAudioFocusChangeListener"){
    onAudioFocusChange = function(focusChange)
      pcall(function()
        local isDuckingEnabled = (prefs.getInt("pref_ducking", 0) == 1)
        if not isDuckingEnabled then return end

        if focusChange == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK or focusChange == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT then
          isFocusDucked = true
          applyVolumeDucking()
        elseif focusChange == AudioManager.AUDIOFOCUS_GAIN then
          isFocusDucked = false
          applyVolumeDucking()
        end
      end)
    end
  }
end)

-- ============================================================================
-- PENGATUR EFEK AUDIO (EQUALIZER, BASS BOOST, ECHO/GEMA)
-- ============================================================================
local eqGenreCurves = {
  {0, 0, 0},     -- Normal
  {7, 2, -3},    -- Hip Hop
  {6, -1, 4},    -- Rock
  {-2, 3, 3},    -- Pop
  {3, 2, 1},     -- Jazz
  {2, 0, -1},    -- Klasik
}

local function applyEqualizerCurve(eq, presetIndex)
  local curve = eqGenreCurves[presetIndex + 1] or eqGenreCurves[1]
  local lowDb, midDb, highDb = curve[1], curve[2], curve[3]

  local numBands = 0
  pcall(function() numBands = eq.getNumberOfBands() end)
  if not numBands or numBands <= 0 then return end

  local minLevel, maxLevel = -1500, 1500
  pcall(function()
    local range = eq.getBandLevelRange()
    minLevel = range[0]
    maxLevel = range[1]
  end)

  for b = 0, numBands - 1 do
    local t = 0
    if numBands > 1 then t = b / (numBands - 1) end
    local db
    if t <= 0.5 then
      db = lowDb + (midDb - lowDb) * (t / 0.5)
    else
      db = midDb + (highDb - midDb) * ((t - 0.5) / 0.5)
    end
    local mb = math.floor(db * 100)
    if mb < minLevel then mb = minLevel end
    if mb > maxLevel then mb = maxLevel end
    pcall(function() eq.setBandLevel(b, mb) end)
  end
end

local function releaseAudioEffects()
  pcall(function()
    if audioEqualizer then
      audioEqualizer.setEnabled(false)
      audioEqualizer.release()
    end
  end)
  audioEqualizer = nil

  pcall(function()
    if audioBassBoost then
      audioBassBoost.setEnabled(false)
      audioBassBoost.release()
    end
  end)
  audioBassBoost = nil

  pcall(function()
    if audioReverb then
      audioReverb.setEnabled(false)
      audioReverb.release()
    end
  end)
  audioReverb = nil
end

local function reapplyEffectSettings()
  pcall(function()
    if audioEqualizer then
      local eqIdx = prefs.getInt("pref_equalizer", 0)
      applyEqualizerCurve(audioEqualizer, eqIdx)
      audioEqualizer.setEnabled(eqIdx ~= 0)
    end
  end)

  pcall(function()
    if audioBassBoost then
      local bassIdx = prefs.getInt("pref_bass", 0)
      local strengths = {0, 300, 600, 900}
      local strength = strengths[bassIdx + 1] or 0
      audioBassBoost.setEnabled(bassIdx > 0)
      audioBassBoost.setStrength(strength)
    end
  end)

  pcall(function()
    if audioReverb then
      local echoIdx = prefs.getInt("pref_echo", 0)
      local presets = {0, 1, 2, 5}
      local preset = presets[echoIdx + 1] or 0
      audioReverb.setEnabled(echoIdx > 0)
      pcall(function() audioReverb.setPreset(preset) end)
    end
  end)
end

local function applyAudioEffects(sessionId)
  releaseAudioEffects()
  if not sessionId or sessionId == 0 then return end

  pcall(function() audioEqualizer = Equalizer(0, sessionId) end)
  pcall(function() audioBassBoost = BassBoost(0, sessionId) end)
  pcall(function() audioReverb = PresetReverb(0, sessionId) end)

  reapplyEffectSettings()
end

-- ============================================================================
-- FITUR PERIKSA & UNDUH OTOMATIS PEMBARUAN
-- ============================================================================
local function downloadScriptText(targetUrl)
  local u = URL(targetUrl)
  local conn = u.openConnection()
  conn.setRequestMethod("GET")
  conn.setConnectTimeout(15000)
  conn.setReadTimeout(15000)
  conn.setUseCaches(false)
  conn.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")
  conn.setRequestProperty("Accept", "*/*")
  conn.setRequestProperty("Cache-Control", "no-cache")

  local code = conn.getResponseCode()
  if code == 200 then
    local is = conn.getInputStream()
    local reader = BufferedReader(InputStreamReader(is, "UTF-8"))
    local lines = {}
    local line = reader.readLine()
    while line ~= nil do
      table.insert(lines, tostring(line))
      line = reader.readLine()
    end
    reader.close()
    is.close()
    conn.disconnect()
    return table.concat(lines, "\n")
  else
    conn.disconnect()
    error("HTTP " .. tostring(code))
  end
end

local function isVersionNewer(remote, localVer)
  if not remote or not localVer then return false end
  local rMaj, rMin, rPat = remote:match("(%d+)%.(%d+)%.?(%d*)")
  local lMaj, lMin, lPat = localVer:match("(%d+)%.(%d+)%.?(%d*)")
  rMaj, rMin, rPat = tonumber(rMaj) or 0, tonumber(rMin) or 0, tonumber(rPat) or 0
  lMaj, lMin, lPat = tonumber(lMaj) or 0, tonumber(lMin) or 0, tonumber(lPat) or 0
  if rMaj > lMaj then return true end
  if rMaj == lMaj and rMin > lMin then return true end
  if rMaj == lMaj and rMin == lMin and rPat > lPat then return true end
  return false
end

local function applyScriptUpdate(newCodeContent, newVersionStr)
  local currentScriptPath = nil
  pcall(function()
    local src = debug.getinfo(1, "S").source
    if src and src:sub(1, 1) == "@" then
      currentScriptPath = src:sub(2)
    end
  end)

  local isSaved = false
  if currentScriptPath and currentScriptPath ~= "" then
    pcall(function()
      local f = File(currentScriptPath)
      local fos = FileOutputStream(f)
      local writer = OutputStreamWriter(fos, "UTF-8")
      writer.write(newCodeContent)
      writer.flush()
      writer.close()
      fos.close()
      isSaved = true
    end)
  end

  local bDone = AlertDialog.Builder(service)
  if isSaved then
    bDone.setTitle("Pembaruan Selesai")
    bDone.setMessage("Pembaruan ke versi v" .. newVersionStr .. " berhasil dipasang.\n\nSilakan tutup dan buka ulang pemutar musik untuk menjalankan versi baru.")
    bDone.setPositiveButton("OKE", DialogInterface.OnClickListener{
      onClick = function(d, w)
        pcall(function()
          if mainDialog then mainDialog.dismiss() end
          service.speak("Pemutar ditutup. Silakan buka kembali untuk menikmati versi baru.")
        end)
      end
    })
    pcall(function() service.speak("Pembaruan selesai dipasang. Silakan buka ulang.") end)
  else
    bDone.setTitle("Gagal Memasang")
    bDone.setMessage("Versi v" .. newVersionStr .. " berhasil diunduh, tetapi gagal menimpa berkas skrip.\n\nPastikan aplikasi memiliki izin penyimpanan.")
    bDone.setPositiveButton("TUTUP", nil)
    pcall(function() service.speak("Gagal menyimpan pembaruan skrip.") end)
  end

  local dlgDone = bDone.create()
  dlgDone.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
  dlgDone.show()
end

local function checkUpdate()
  pcall(function() service.speak("Sedang memeriksa versi baru...") end)
  Thread(Runnable{
    run = function()
      local isSuccess = false
      local remoteCode = nil
      local lastErrMsg = "Koneksi waktu habis (timeout)"
      local timeStamp = tostring(System.currentTimeMillis())

      local urlsToTry = {
        UPDATE_URL .. "?t=" .. timeStamp,
        "https://fastly.jsdelivr.net/gh/novanblind/Pemutar-musik@main/Musicplayer.lua?t=" .. timeStamp,
        "https://cdn.jsdelivr.net/gh/novanblind/Pemutar-musik@main/Musicplayer.lua?t=" .. timeStamp,
        "https://raw.githack.com/novanblind/Pemutar-musik/main/Musicplayer.lua?t=" .. timeStamp
      }

      for _, u in ipairs(urlsToTry) do
        local ok, result = pcall(function()
          return downloadScriptText(u)
        end)
        if ok and result and #result > 100 and result:find("APP_VERSION") then
          isSuccess = true
          remoteCode = result
          break
        else
          if not ok and result then
            lastErrMsg = tostring(result):gsub(".-:%s*", "")
          end
        end
      end

      mainHandler.post(Runnable{
        run = function()
          if isSuccess and remoteCode then
            local remoteVersion = remoteCode:match('APP_VERSION%s*=%s*["\']([^"\']+)["\']')

            if not remoteVersion then
              pcall(function() service.speak("Gagal membaca struktur versi dari server.") end)
              return
            end

            if isVersionNewer(remoteVersion, APP_VERSION) then
              local bUp = AlertDialog.Builder(service)
              bUp.setTitle("Versi Baru Tersedia")
              bUp.setMessage("Versi saat ini: v" .. APP_VERSION .. "\nVersi terbaru: v" .. remoteVersion .. "\n\nApakah Anda ingin memperbarui sekarang?")
              bUp.setPositiveButton("PERBARUI", DialogInterface.OnClickListener{
                onClick = function(d, w)
                  pcall(function()
                    service.speak("Menerapkan pembaruan skrip...")
                    applyScriptUpdate(remoteCode, remoteVersion)
                  end)
                end
              })
              bUp.setNegativeButton("BATAL", nil)
              local dlgUp = bUp.create()
              dlgUp.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
              dlgUp.show()
              pcall(function() service.speak("Versi baru v" .. remoteVersion .. " tersedia.") end)
            else
              local bUp = AlertDialog.Builder(service)
              bUp.setTitle("Pemeriksaan Versi")
              bUp.setMessage("Aplikasi Anda sudah menggunakan versi terbaru (v" .. APP_VERSION .. ").")
              bUp.setPositiveButton("OKE", nil)
              local dlgUp = bUp.create()
              dlgUp.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
              dlgUp.show()
              pcall(function() service.speak("Aplikasi sudah versi terbaru v" .. APP_VERSION) end)
            end
          else
            local msg = "Gagal memeriksa versi baru: " .. lastErrMsg
            pcall(function() service.speak(msg) end)
          end
        end
      })
    end
  }).start()
end

-- ============================================================================
-- PEMINDAI BERKAS AUDIO & PENGELOMPOKAN FOLDER KONSISTEN
-- ============================================================================
local prepareNextTrackGapless = nil
local txtFolderInfo = nil

local function scanAudioFiles(dir, list, pathSet, depth)
  depth = depth or 0
  if depth > 12 then return end
  pcall(function()
    if not dir or not dir.exists() or not dir.canRead() then return end
    local files = dir.listFiles()
    if not files then return end
    local len = Array.getLength(files)
    for i = 0, len - 1 do
      local f = files[i]
      if f then
        local name = f.getName()
        if f.isDirectory() then
          local lowerName = name:lower()
          if not name:find("^%.") and lowerName ~= "android" and lowerName ~= "data" and lowerName ~= "obb" then
            scanAudioFiles(f, list, pathSet, depth + 1)
          end
        elseif f.isFile() then
          local lower = name:lower()
          if lower:find("%.mp3$") or lower:find("%.m4a$") or lower:find("%.wav$") or lower:find("%.ogg$") or lower:find("%.flac$") or lower:find("%.aac$") or lower:find("%.opus$") then
            local absPath = f.getAbsolutePath()
            if not pathSet[absPath] then
              pathSet[absPath] = true
              table.insert(list, absPath)
            end
          end
        end
      end
    end
  end)
end

local function performScan(silent)
  local tempSongList = {}
  local pathSet = {}

  pcall(function()
    local resolver = service.getContentResolver()
    local cursor = resolver.query(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, nil, nil, nil, nil)
    if cursor then
      local colData = cursor.getColumnIndex("_data")
      if colData >= 0 then
        while cursor.moveToNext() do
          local p = cursor.getString(colData)
          if p and p ~= "" and not pathSet[p] then
            local f = File(p)
            if f.exists() and f.isFile() then
              local lower = f.getName():lower()
              if lower:find("%.mp3$") or lower:find("%.m4a$") or lower:find("%.wav$") or lower:find("%.ogg$") or lower:find("%.flac$") or lower:find("%.aac$") or lower:find("%.opus$") then
                pathSet[p] = true
                table.insert(tempSongList, p)
              end
            end
          end
        end
      end
      cursor.close()
    end
  end)

  local pathsToScan = {}
  pcall(function()
    local extDirs = service.getExternalFilesDirs(nil)
    if extDirs then
      local len = Array.getLength(extDirs)
      for i = 0, len - 1 do
        local d = extDirs[i]
        if d then
          local abs = d.getAbsolutePath()
          local root = abs:match("(/storage/[^/]+)")
          if root and root ~= "/storage/emulated" and root ~= "/storage/self" then
            table.insert(pathsToScan, root)
          end
        end
      end
    end
  end)

  pcall(function()
    local storageRoot = File("/storage")
    if storageRoot.exists() and storageRoot.isDirectory() then
      local list = storageRoot.listFiles()
      if list then
        local len = Array.getLength(list)
        for i = 0, len - 1 do
          local disk = list[i]
          local diskName = disk.getName()
          if disk.isDirectory() and diskName ~= "emulated" and diskName ~= "self" and not diskName:find("^%.") then
            table.insert(pathsToScan, disk.getAbsolutePath())
          end
        end
      end
    end
  end)

  local internalRoot = Environment.getExternalStorageDirectory().getAbsolutePath()
  table.insert(pathsToScan, internalRoot .. "/Music")
  table.insert(pathsToScan, internalRoot .. "/Download")
  table.insert(pathsToScan, internalRoot .. "/gemini tts")

  for _, p in ipairs(pathsToScan) do
    local f = File(p)
    if f.exists() then
      scanAudioFiles(f, tempSongList, pathSet, 0)
    end
  end

  table.sort(tempSongList, function(a, b)
    return File(a).getName():lower() < File(b).getName():lower()
  end)

  local tempFolderList = {}
  local folderMap = {}
  for _, p in ipairs(tempSongList) do
    local parent = File(p).getParent()
    if parent then
      if not folderMap[parent] then
        local fName = File(parent).getName()
        folderMap[parent] = {
          name = fName,
          path = parent,
          songs = {}
        }
        table.insert(tempFolderList, folderMap[parent])
      end
      table.insert(folderMap[parent].songs, p)
    end
  end

  table.sort(tempFolderList, function(a, b)
    return a.name:lower() < b.name:lower()
  end)

  for _, fData in ipairs(tempFolderList) do
    table.sort(fData.songs, function(a, b)
      return File(a).getName():lower() < File(b).getName():lower()
    end)
  end

  mainHandler.post(Runnable{
    run = function()
      songList = tempSongList
      folderList = tempFolderList

      if currentFolderPath ~= "" and currentFolderPath ~= "SEARCH" and currentFolderPath ~= "FAVORITES" then
        local foundFolder = nil
        for _, f in ipairs(folderList) do
          if f.path == currentFolderPath then
            foundFolder = f
            break
          end
        end

        if foundFolder then
          filteredSongs = foundFolder.songs
          currentFolderName = foundFolder.name
        else
          currentFolderPath = ""
          currentFolderName = "Semua Lagu"
          filteredSongs = songList
        end
      elseif currentFolderPath == "FAVORITES" then
      elseif currentFolderPath == "SEARCH" then
      else
        currentFolderPath = ""
        currentFolderName = "Semua Lagu"
        filteredSongs = songList
      end

      if txtFolderInfo then
        txtFolderInfo.setText("Folder: " .. currentFolderName)
      end

      if currentSongPath ~= "" then
        for idx, p in ipairs(filteredSongs) do
          if p == currentSongPath then
            currentIndex = idx
            sysProps.put("GLOBAL_ADV_SONG_INDEX", tostring(currentIndex))
            break
          end
        end
      end

      if prepareNextTrackGapless then
        prepareNextTrackGapless()
      end

      if not silent then
        pcall(function()
          service.speak("Pemindaian selesai. Berhasil menemukan " .. #songList .. " lagu di " .. #folderList .. " folder.")
        end)
      end
    end
  })
end

-- ============================================================================
-- HELPER TAMPILAN
-- ============================================================================
local function makeColLp(weight)
  local lp = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, weight or 1.0)
  lp.setMargins(2, 2, 2, 2)
  return lp
end

local playTrack = nil
local applyPitchAndSpeed = nil
local startCrossfadeTo = nil

-- Dialog Atur Nada & Tempo
local function showPitchSpeedDialog()
  local b = AlertDialog.Builder(service)
  b.setTitle("Nada & Kecepatan Putar")
  local v = LinearLayout(service)
  v.setOrientation(LinearLayout.VERTICAL)
  v.setPadding(30, 20, 30, 20)

  local rowP = LinearLayout(service)
  rowP.setOrientation(LinearLayout.HORIZONTAL)
  local btnPitchDown = Button(service)
  btnPitchDown.setText("NADA -")
  local btnPitchUp = Button(service)
  btnPitchUp.setText("NADA +")
  rowP.addView(btnPitchDown, makeColLp(1.0))
  rowP.addView(btnPitchUp, makeColLp(1.0))
  v.addView(rowP)

  local btnSpeed = Button(service)
  btnSpeed.setText("PILIH KECEPATAN (TEMPO)")
  v.addView(btnSpeed)

  btnPitchUp.setOnClickListener(View.OnClickListener{
    onClick = function(view)
      currentPitch = math.min(2.0, currentPitch + 0.1)
      applyPitchAndSpeed()
      pcall(function() prefs.edit().putFloat("pref_pitch_value", currentPitch).apply() end)
      pcall(function() service.speak(string.format("Nada: %.1fx", currentPitch)) end)
    end
  })

  btnPitchDown.setOnClickListener(View.OnClickListener{
    onClick = function(view)
      currentPitch = math.max(0.5, currentPitch - 0.1)
      applyPitchAndSpeed()
      pcall(function() prefs.edit().putFloat("pref_pitch_value", currentPitch).apply() end)
      pcall(function() service.speak(string.format("Nada: %.1fx", currentPitch)) end)
    end
  })

  btnSpeed.setOnClickListener(View.OnClickListener{
    onClick = function(view)
      local bSp = AlertDialog.Builder(service)
      bSp.setTitle("Pilih Kecepatan")
      bSp.setItems(SPEED_LABELS, DialogInterface.OnClickListener{
        onClick = function(d, which)
          currentSpeed = SPEED_VALUES[which + 1]
          prefs.edit().putInt("pref_speed", which).apply()
          applyPitchAndSpeed()
          pcall(function() service.speak("Kecepatan: " .. SPEED_LABELS[which + 1]) end)
        end
      })
      local dlgSp = bSp.create()
      dlgSp.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
      dlgSp.show()
    end
  })

  b.setView(v)
  b.setPositiveButton("Selesai", nil)
  local dlg = b.create()
  dlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
  dlg.show()
end

-- Dialog Pengulangan A-B
local function showABLoopDialog()
  local b = AlertDialog.Builder(service)
  b.setTitle("Pengulangan A-B")
  local v = LinearLayout(service)
  v.setOrientation(LinearLayout.VERTICAL)
  v.setPadding(30, 20, 30, 20)

  local btnLoopStart = Button(service)
  btnLoopStart.setText("TETAPKAN TITIK AWAL (A)")
  v.addView(btnLoopStart)

  local btnLoopEnd = Button(service)
  btnLoopEnd.setText("TETAPKAN TITIK AKHIR (B)")
  v.addView(btnLoopEnd)

  local btnLoopClear = Button(service)
  btnLoopClear.setText("HAPUS PENGULANGAN A-B")
  v.addView(btnLoopClear)

  btnLoopStart.setOnClickListener(View.OnClickListener{
    onClick = function(view)
      pcall(function()
        if mediaPlayer then
          loopA = mediaPlayer.getCurrentPosition()
          service.speak("Titik loop A: " .. formatTime(loopA))
        end
      end)
    end
  })

  btnLoopEnd.setOnClickListener(View.OnClickListener{
    onClick = function(view)
      pcall(function()
        if mediaPlayer then
          loopB = mediaPlayer.getCurrentPosition()
          if loopB > loopA then
            isLoopingAB = true
            service.speak("Titik loop B: " .. formatTime(loopB) .. ". Loop aktif.")
          else
            service.speak("Titik B harus lebih besar dari titik A.")
          end
        end
      end)
    end
  })

  btnLoopClear.setOnClickListener(View.OnClickListener{
    onClick = function(view)
      isLoopingAB = false
      loopA = 0
      loopB = 0
      pcall(function() service.speak("Pengulangan A-B dinonaktifkan.") end)
    end
  })

  b.setView(v)
  b.setPositiveButton("Tutup", nil)
  local dlg = b.create()
  dlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
  dlg.show()
end

-- Dialog Tentang Aplikasi
local function showAboutDialog()
  local b = AlertDialog.Builder(service)
  b.setTitle("Tentang Aplikasi")
  b.setMessage("Pemutar Musik Folder Jieshuo+\nVersi: " .. APP_VERSION .. "\n\nFitur lengkap dengan penguncian folder pemutaran konsisten, kontrol navigasi ringkas, acak khusus dalam folder, resume posisi opsional, transisi sambung instan tanpa jeda (Gapless & Crossfade JetAudio), Audio Ducking saat bicara/rekam, Audio FX, dan pembaruan GitHub anti-timeout.")
  b.setPositiveButton("Tutup", nil)
  local dlg = b.create()
  dlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
  dlg.show()
end

-- ============================================================================
-- PENGATURAN (SETTINGS DIALOG)
-- ============================================================================
local function showSettingsDialog(onSettingsUpdated, txtFInfo, txtSTitle)
  local b = AlertDialog.Builder(service)
  b.setTitle("Pengaturan")

  local scroll = ScrollView(service)
  scroll.setFillViewport(true)

  local box = LinearLayout(service)
  box.setOrientation(LinearLayout.VERTICAL)
  box.setPadding(35, 20, 35, 25)

  local optShuffle = {"Mati", "Acak Folder Saja", "Acak Semua Lagu"}
  local optRepeat = {"Mati", "Ulangi Lagu Ini", "Ulangi Folder Ini"}
  local optResume = {"Mati", "Hidup"}
  local optSpeed = SPEED_LABELS
  local optDuration = {"5 Detik", "10 Detik", "15 Detik", "30 Detik"}
  local optSleep = {"Mati", "10 Menit", "15 Menit", "30 Menit", "45 Menit", "60 Menit"}
  local optEqualizer = {"Normal", "Hip Hop", "Rock", "Pop", "Jazz", "Klasik"}
  local optEcho = {"Tidak Ada", "Ruangan Kecil", "Ruangan Sedang", "Aula Besar"}
  local optBass = {"Mati", "Rendah", "Sedang", "Kuat"}
  local optCrossfade = {"Mati", "Hidup"}
  local optCrossfadeDur = {"3 Detik", "5 Detik", "8 Detik", "10 Detik", "12 Detik", "15 Detik"}
  local optDucking = {"Mati", "Hidup"}

  local spinners = {}

  local function addSettingSpinner(labelStr, items, prefKey, defIndex)
    local lbl = TextView(service)
    lbl.setText(labelStr)
    lbl.setTextSize(14)
    lbl.setPadding(0, 12, 0, 4)
    box.addView(lbl)

    local sp = Spinner(service)
    sp.setAdapter(ArrayAdapter(service, android.R.layout.simple_spinner_dropdown_item, items))
    local savedIdx = prefs.getInt(prefKey, defIndex)
    if savedIdx >= 0 and savedIdx < #items then
      sp.setSelection(savedIdx)
    end
    box.addView(sp)
    spinners[prefKey] = { spinner = sp, items = items }
  end

  local prevSleepIdx = prefs.getInt("pref_sleep_timer", 0)

  addSettingSpinner("Acak (Shuffle):", optShuffle, "pref_shuffle", 0)
  addSettingSpinner("Pengulangan (Repeat):", optRepeat, "pref_repeat", 0)
  -- Bawaan (default) Resume dimatikan (index 0 = "Mati")
  addSettingSpinner("Lanjutkan Posisi Terakhir (Resume):", optResume, "pref_resume", 0)
  addSettingSpinner("Peredam Audio saat Bicara & Rekam (Ducking):", optDucking, "pref_ducking", 0)
  addSettingSpinner("Kecepatan Putar (Playback Speed):", optSpeed, "pref_speed", 2)
  addSettingSpinner("Durasi Mundur / Maju:", optDuration, "pref_seek_step", 1)
  addSettingSpinner("Pengatur Waktu Tidur (Sleep Timer):", optSleep, "pref_sleep_timer", 0)
  addSettingSpinner("Equalizer:", optEqualizer, "pref_equalizer", 0)
  addSettingSpinner("Efek Gema / Ruang (Echo Sound):", optEcho, "pref_echo", 0)
  addSettingSpinner("Penguat Bass (Bass Boost):", optBass, "pref_bass", 0)
  addSettingSpinner("Transisi Mulus (Crossfade):", optCrossfade, "pref_crossfade", 1)
  addSettingSpinner("Durasi Crossfade:", optCrossfadeDur, "pref_crossfade_dur", 1)

  local dlg = nil

  local btnSubPitch = Button(service)
  btnSubPitch.setText("ATUR NADA & TEMPO")
  btnSubPitch.setOnClickListener(View.OnClickListener{ onClick = function(v) showPitchSpeedDialog() end })
  box.addView(btnSubPitch)

  local btnSubLoop = Button(service)
  btnSubLoop.setText("PENGULANGAN A-B (LOOP)")
  btnSubLoop.setOnClickListener(View.OnClickListener{ onClick = function(v) showABLoopDialog() end })
  box.addView(btnSubLoop)

  local btnCheckUpdate = Button(service)
  btnCheckUpdate.setText("PERIKSA VERSI BARU")
  btnCheckUpdate.setOnClickListener(View.OnClickListener{ onClick = function(v) checkUpdate() end })
  box.addView(btnCheckUpdate)

  local btnSubAbout = Button(service)
  btnSubAbout.setText("TENTANG APLIKASI")
  btnSubAbout.setOnClickListener(View.OnClickListener{ onClick = function(v) showAboutDialog() end })
  box.addView(btnSubAbout)

  local btnReset = Button(service)
  btnReset.setText("RESET PENGATURAN")
  btnReset.setOnClickListener(View.OnClickListener{
    onClick = function(v)
      pcall(function()
        local ed = prefs.edit()
        local allEntries = prefs.getAll()
        if allEntries then
          local it = allEntries.keySet().iterator()
          while it.hasNext() do
            local k = tostring(it.next())
            if k:find("^pref_") then
              ed.remove(k)
            end
          end
        end
        ed.apply()
      end)

      currentPitch = 1.0
      currentSpeed = 1.0
      applyPitchAndSpeed()
      isSleepTimerArmed = false

      pcall(function() service.speak("Pengaturan telah direset ke setelan awal.") end)
      if dlg then dlg.dismiss() end
      if onSettingsUpdated then onSettingsUpdated() end
    end
  })
  box.addView(btnReset)

  local btnClose = Button(service)
  btnClose.setText("TUTUP")
  btnClose.setOnClickListener(View.OnClickListener{
    onClick = function(v)
      local ed = prefs.edit()
      for k, data in pairs(spinners) do
        ed.putInt(k, data.spinner.getSelectedItemPosition())
      end
      ed.apply()

      if spinners["pref_speed"] then
        local newSpeedIdx = spinners["pref_speed"].spinner.getSelectedItemPosition()
        local newSpeedVal = SPEED_VALUES[newSpeedIdx + 1]
        if newSpeedVal then
          currentSpeed = newSpeedVal
          applyPitchAndSpeed()
        end
      end

      local newSleepIdx = spinners["pref_sleep_timer"] and spinners["pref_sleep_timer"].spinner.getSelectedItemPosition() or prevSleepIdx
      if newSleepIdx ~= prevSleepIdx then
        isSleepTimerArmed = false
      end

      applyVolumeDucking()
      if dlg then dlg.dismiss() end
      if onSettingsUpdated then onSettingsUpdated() end
      pcall(function() service.speak("Pengaturan disimpan.") end)
    end
  })
  box.addView(btnClose)

  scroll.addView(box)
  b.setView(scroll)
  dlg = b.create()
  dlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
  dlg.show()
end

-- ============================================================================
-- TAMPILAN UTAMA
-- ============================================================================
local layout = LinearLayout(service)
layout.setOrientation(LinearLayout.VERTICAL)
layout.setPadding(20, 12, 20, 16)

local scroll = ScrollView(service)
scroll.setFillViewport(true)

local container = LinearLayout(service)
container.setOrientation(LinearLayout.VERTICAL)

local txtTitle = TextView(service)
txtTitle.setText("Pemutar Musik Folder")
txtTitle.setTextSize(17)
txtTitle.setGravity(Gravity.CENTER)
txtTitle.setPadding(0, 4, 0, 4)
container.addView(txtTitle)

txtFolderInfo = TextView(service)
txtFolderInfo.setText("Folder: " .. currentFolderName)
txtFolderInfo.setTextSize(13)
txtFolderInfo.setGravity(Gravity.CENTER)
txtFolderInfo.setPadding(0, 0, 0, 2)
container.addView(txtFolderInfo)

local txtSongTitle = TextView(service)
txtSongTitle.setText("Tidak ada lagu diputar")
txtSongTitle.setTextSize(15)
txtSongTitle.setGravity(Gravity.CENTER)
txtSongTitle.setPadding(0, 2, 0, 2)
container.addView(txtSongTitle)

local txtTimer = TextView(service)
txtTimer.setText("0:00 / 0:00")
txtTimer.setTextSize(13)
txtTimer.setGravity(Gravity.CENTER)
txtTimer.setPadding(0, 0, 0, 4)
container.addView(txtTimer)

local sbProgress = SeekBar(service)
sbProgress.setMax(100)
container.addView(sbProgress)

-- BARIS 1: KONTROL PUTAR
local rowPlayback = LinearLayout(service)
rowPlayback.setOrientation(LinearLayout.HORIZONTAL)

local btnPrev = Button(service)
btnPrev.setText("SEBELUM")
btnPrev.setTextSize(11)

local btnRewind = Button(service)
btnRewind.setText("MUNDUR")
btnRewind.setTextSize(11)

local btnPlay = Button(service)
btnPlay.setText("PUTAR")
btnPlay.setTextSize(12)

local btnForward = Button(service)
btnForward.setText("MAJU")
btnForward.setTextSize(11)

local btnNext = Button(service)
btnNext.setText("LANJUT")
btnNext.setTextSize(11)

rowPlayback.addView(btnPrev, makeColLp(1.0))
rowPlayback.addView(btnRewind, makeColLp(1.0))
rowPlayback.addView(btnPlay, makeColLp(1.2))
rowPlayback.addView(btnForward, makeColLp(1.0))
rowPlayback.addView(btnNext, makeColLp(1.0))
container.addView(rowPlayback)

-- BARIS 2: FOLDER, DAFTAR LAGU, & PENGULANGAN
local rowFolderSong = LinearLayout(service)
rowFolderSong.setOrientation(LinearLayout.HORIZONTAL)
local btnFolders = Button(service)
btnFolders.setText("FOLDER")
local btnSongList = Button(service)
btnSongList.setText("DAFTAR LAGU")
local btnRepeat = Button(service)
btnRepeat.setText("ULANG: MATI")

rowFolderSong.addView(btnFolders, makeColLp(1.0))
rowFolderSong.addView(btnSongList, makeColLp(1.0))
rowFolderSong.addView(btnRepeat, makeColLp(1.1))
container.addView(rowFolderSong)

-- BARIS 3: CARI, SEMUA LAGU, PUSTAKA, & FAVORIT
local rowLibSearch = LinearLayout(service)
rowLibSearch.setOrientation(LinearLayout.HORIZONTAL)
local btnSearch = Button(service)
btnSearch.setText("CARI")
local btnClear = Button(service)
btnClear.setText("SEMUA")
local btnLibrary = Button(service)
btnLibrary.setText("PUSTAKA")
local btnFav = Button(service)
btnFav.setText("+ FAVORIT")

rowLibSearch.addView(btnSearch, makeColLp(1.0))
rowLibSearch.addView(btnClear, makeColLp(1.0))
rowLibSearch.addView(btnLibrary, makeColLp(1.0))
rowLibSearch.addView(btnFav, makeColLp(1.0))
container.addView(rowLibSearch)

-- BARIS 4: PINDAI, SETELAN, LATAR BELAKANG, & KELUAR
local rowBottom = LinearLayout(service)
rowBottom.setOrientation(LinearLayout.HORIZONTAL)
local btnRescan = Button(service)
btnRescan.setText("PINDAI")
local btnSettings = Button(service)
btnSettings.setText("SETELAN")
local btnBackground = Button(service)
btnBackground.setText("LATAR")
local btnExit = Button(service)
btnExit.setText("HENTIKAN")

rowBottom.addView(btnRescan, makeColLp(1.0))
rowBottom.addView(btnSettings, makeColLp(1.0))
rowBottom.addView(btnBackground, makeColLp(1.0))
rowBottom.addView(btnExit, makeColLp(1.0))
container.addView(rowBottom)

scroll.addView(container)
layout.addView(scroll)

local dialogBuilder = AlertDialog.Builder(service)
dialogBuilder.setView(layout)
mainDialog = dialogBuilder.create()
local win = mainDialog.getWindow()
win.setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
win.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
mainDialog.show()

-- ============================================================================
-- STATUS PENGULANGAN (REPEAT)
-- ============================================================================
local repeatLabels = {"ULANG: MATI", "ULANG: LAGU", "ULANG: FOLDER"}
local repeatSpoken = {"Pengulangan mati", "Ulangi lagu ini", "Ulangi folder ini"}

local function updateRepeatButtonUI()
  local rep = prefs.getInt("pref_repeat", 0)
  if rep < 0 or rep > 2 then rep = 0 end
  btnRepeat.setText(repeatLabels[rep + 1])
end
updateRepeatButtonUI()

btnRepeat.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    local currentRep = prefs.getInt("pref_repeat", 0)
    local nextRep = (currentRep + 1) % 3
    prefs.edit().putInt("pref_repeat", nextRep).apply()
    updateRepeatButtonUI()
    pcall(function() service.speak(repeatSpoken[nextRep + 1]) end)
    prepareNextTrackGapless()
  end
})

-- ============================================================================
-- LOGIKA TRANSISI: CROSSFADE & GAPLESS JETAUDIO
-- ============================================================================
local function getSeekStepMs()
  local steps = {5000, 10000, 15000, 30000}
  local idx = prefs.getInt("pref_seek_step", 1) + 1
  return steps[idx] or 10000
end

local function getCrossfadeDurMs()
  local durs = {3000, 5000, 8000, 10000, 12000, 15000}
  local idx = prefs.getInt("pref_crossfade_dur", 1) + 1
  return durs[idx] or 5000
end

local function refreshButtonLabels()
  local sec = math.floor(getSeekStepMs() / 1000)
  btnRewind.setText("MUNDUR " .. sec .. "D")
  btnForward.setText("MAJU " .. sec .. "D")
end
refreshButtonLabels()

applyPitchAndSpeed = function()
  pcall(function()
    if mediaPlayer and Build.VERSION.SDK_INT >= 23 then
      local params = mediaPlayer.getPlaybackParams()
      params.setPitch(currentPitch)
      params.setSpeed(currentSpeed)
      mediaPlayer.setPlaybackParams(params)
    end
  end)
end

local function applySleepTimer()
  if isSleepTimerArmed then return end

  if sleepTimerRunnable then
    mainHandler.removeCallbacks(sleepTimerRunnable)
    sleepTimerRunnable = nil
  end
  local timerIdx = prefs.getInt("pref_sleep_timer", 0)
  local timerMinutes = {0, 10, 15, 30, 45, 60}
  local min = timerMinutes[timerIdx + 1] or 0
  if min > 0 then
    sleepTimerRunnable = Runnable{
      run = function()
        pcall(function()
          if mediaPlayer and mediaPlayer.isPlaying() then
            mediaPlayer.pause()
            btnPlay.setText("PUTAR")
            isPlaying = false
          end
          service.speak("Pengatur waktu tidur selesai. Musik dimatikan.")
        end)
        isSleepTimerArmed = false
      end
    }
    mainHandler.postDelayed(sleepTimerRunnable, min * 60 * 1000)
    isSleepTimerArmed = true
  end
end

local function cancelSleepTimer()
  if sleepTimerRunnable then
    mainHandler.removeCallbacks(sleepTimerRunnable)
    sleepTimerRunnable = nil
  end
  isSleepTimerArmed = false
end

-- Aturan Pengulangan & Acak (Konsisten Mengikuti Folder)
local function getNextTrackIndex()
  if #filteredSongs == 0 then return -1 end
  local repeatMode = prefs.getInt("pref_repeat", 0)
  local shuffleMode = prefs.getInt("pref_shuffle", 0)

  if repeatMode == 1 then
    return currentIndex
  elseif shuffleMode == 1 and #filteredSongs > 1 then
    local r = math.random(1, #filteredSongs)
    if r == currentIndex and #filteredSongs > 1 then
      r = (currentIndex % #filteredSongs) + 1
    end
    return r
  elseif shuffleMode == 2 and #songList > 1 then
    local r = math.random(1, #songList)
    local targetSong = songList[r]
    for i, p in ipairs(filteredSongs) do
      if p == targetSong then return i end
    end
    filteredSongs = songList
    currentFolderPath = ""
    currentFolderName = "Semua Lagu"
    txtFolderInfo.setText("Folder: Semua Lagu")
    local ed = prefs.edit()
    ed.putString("last_folder_path", "")
    ed.putString("last_folder_name", "Semua Lagu")
    ed.apply()
    return r
  elseif currentIndex < #filteredSongs then
    return currentIndex + 1
  elseif repeatMode == 2 and #filteredSongs > 0 then
    return 1
  else
    return -1
  end
end

-- Eksekutor Pudar Suara Halus (Volume Fader)
local function fadeVolume(player, startVol, targetVol, durationMs, callback)
  if not player then
    if callback then callback() end
    return
  end
  local interval = 50
  local steps = math.max(1, math.floor(durationMs / interval))
  local stepTime = math.max(10, math.floor(durationMs / steps))
  local currentStep = 0
  local diff = targetVol - startVol

  local r
  r = Runnable{
    run = function()
      currentStep = currentStep + 1
      local progress = currentStep / steps
      if progress > 1 then progress = 1 end
      local v = startVol + (diff * progress)
      pcall(function()
        if player then
          player.setVolume(v, v)
        end
      end)
      if currentStep < steps then
        mainHandler.postDelayed(r, stepTime)
      else
        if callback then callback() end
      end
    end
  }
  pcall(function() player.setVolume(startVol, startVol) end)
  mainHandler.post(r)
end

local attachCompletionListener = nil

local function finishCrossfadeImmediately()
  if not isCrossfading then return end
  pcall(function()
    for _, p in ipairs(fadingOldPlayers) do
      pcall(function() p.stop() end)
      pcall(function() p.release() end)
    end
  end)
  fadingOldPlayers = {}
  pcall(function()
    if mediaPlayer then
      local maxV = getCurrentMaxVolume()
      mediaPlayer.setVolume(maxV, maxV)
    end
  end)
  isCrossfading = false
end

-- Persiapan Pemutar Lagu Berikutnya (Selalu Siaga agar Pergantian Otomatis Instan Tanpa Jeda)
prepareNextTrackGapless = function()
  pcall(function()
    if nextMediaPlayer then
      pcall(function() nextMediaPlayer.release() end)
      nextMediaPlayer = nil
    end

    if not mediaPlayer or #filteredSongs == 0 then return end

    local isCrossfadeOn = (prefs.getInt("pref_crossfade", 1) == 1)
    local nextIdx = getNextTrackIndex()

    if nextIdx > 0 and filteredSongs[nextIdx] then
      local nextPath = filteredSongs[nextIdx]
      nextMediaPlayer = MediaPlayer()
      nextMediaPlayer.setDataSource(nextPath)
      nextMediaPlayer.prepare()

      if not isCrossfadeOn then
        pcall(function()
          mediaPlayer.setNextMediaPlayer(nextMediaPlayer)
        end)
      else
        pcall(function()
          mediaPlayer.setNextMediaPlayer(nil)
        end)
      end

      sysProps.put("GLOBAL_ADV_NEXT_INDEX", tostring(nextIdx))
    else
      sysProps.remove("GLOBAL_ADV_NEXT_INDEX")
    end
  end)
end

-- Listener Selesai Putar Lagu (Menyambung Otomatis Tanpa Jeda Saat Lagu Habis)
attachCompletionListener = function(player)
  player.setOnCompletionListener(luajava.bindClass("android.media.MediaPlayer$OnCompletionListener"){
    onCompletion = function(mp)
      pcall(function()
        if player ~= mediaPlayer then
          pcall(function() mp.release() end)
          return
        end

        prefs.edit().putInt("last_played_pos", 0).apply()

        isLoopingAB = false
        loopA = 0
        loopB = 0

        local nextIdx = tonumber(sysProps.get("GLOBAL_ADV_NEXT_INDEX") or "-1")

        -- Jika pemutar lagu berikutnya sudah disiapkan, langsung sambung instan tanpa proses prepare baru
        if nextMediaPlayer and nextIdx and nextIdx > 0 and filteredSongs[nextIdx] then
          pcall(function() mp.release() end)
          mediaPlayer = nextMediaPlayer
          nextMediaPlayer = nil
          currentIndex = nextIdx
          currentSongPath = filteredSongs[currentIndex]
          isPlaying = true
          if btnPlay then btnPlay.setText("JEDA") end

          sysProps.put("GLOBAL_ADV_MEDIA_PLAYER", mediaPlayer)
          sysProps.put("GLOBAL_ADV_SONG_PATH", currentSongPath)
          sysProps.put("GLOBAL_ADV_SONG_INDEX", tostring(currentIndex))
          prefs.edit().putString("last_played_path", currentSongPath).apply()

          pcall(function()
            if txtSongTitle then txtSongTitle.setText(File(currentSongPath).getName()) end
            if txtFolderInfo then txtFolderInfo.setText("Folder: " .. currentFolderName) end
          end)

          local maxV = getCurrentMaxVolume()
          pcall(function() mediaPlayer.setVolume(maxV, maxV) end)
          pcall(function() mediaPlayer.start() end)
          applyPitchAndSpeed()
          pcall(function() applyAudioEffects(mediaPlayer.getAudioSessionId()) end)
          applyVolumeDucking()
          attachCompletionListener(mediaPlayer)
          prepareNextTrackGapless()
          return
        end

        local nIdx = getNextTrackIndex()
        if nIdx > 0 and filteredSongs[nIdx] then
          currentIndex = nIdx
          playTrack(filteredSongs[currentIndex], 0)
        else
          isPlaying = false
          if btnPlay then btnPlay.setText("PUTAR") end
        end
      end)
    end
  })
end

-- Mesin Transisi Pudar Silang (Crossfade JetAudio)
startCrossfadeTo = function(nextPath, nextIdx, durMs)
  if isCrossfading then return end
  isCrossfading = true

  local oldPlayer = mediaPlayer
  local maxVol = getCurrentMaxVolume()
  local newPlayer = nil

  local nextSavedIdx = tonumber(sysProps.get("GLOBAL_ADV_NEXT_INDEX") or "-1")
  if nextMediaPlayer and nextSavedIdx == nextIdx then
    newPlayer = nextMediaPlayer
    nextMediaPlayer = nil
  else
    newPlayer = MediaPlayer()
    local okPrep = pcall(function()
      newPlayer.setDataSource(nextPath)
      newPlayer.prepare()
    end)
    if not okPrep then
      isCrossfading = false
      pcall(function() newPlayer.release() end)
      return
    end
  end

  pcall(function()
    newPlayer.setVolume(0.0, 0.0)
    newPlayer.start()
  end)

  mediaPlayer = newPlayer
  currentIndex = nextIdx
  currentSongPath = nextPath
  isPlaying = true
  if btnPlay then btnPlay.setText("JEDA") end

  isLoopingAB = false
  loopA = 0
  loopB = 0

  pcall(function()
    local f = File(nextPath)
    if txtSongTitle then txtSongTitle.setText(f.getName()) end
    if txtFolderInfo then txtFolderInfo.setText("Folder: " .. currentFolderName) end
  end)

  sysProps.put("GLOBAL_ADV_MEDIA_PLAYER", mediaPlayer)
  sysProps.put("GLOBAL_ADV_SONG_PATH", nextPath)
  sysProps.put("GLOBAL_ADV_SONG_INDEX", tostring(currentIndex))

  local ed = prefs.edit()
  ed.putString("last_played_path", nextPath)
  ed.putInt("last_played_pos", 0)
  ed.apply()

  applyPitchAndSpeed()
  pcall(function() applyAudioEffects(newPlayer.getAudioSessionId()) end)
  applySleepTimer()
  attachCompletionListener(mediaPlayer)

  -- Fade-In pemutar lagu baru
  fadeVolume(newPlayer, 0.0, maxVol, durMs, function()
    isCrossfading = false
    prepareNextTrackGapless()
  end)

  -- Fade-Out pemutar lagu lama
  if oldPlayer then
    table.insert(fadingOldPlayers, oldPlayer)
    fadeVolume(oldPlayer, maxVol, 0.0, durMs, function()
      pcall(function()
        oldPlayer.stop()
        oldPlayer.release()
      end)
      for idx, p in ipairs(fadingOldPlayers) do
        if p == oldPlayer then
          table.remove(fadingOldPlayers, idx)
          break
        end
      end
    end)
  end
end

-- Pemutar Lagu Utama
playTrack = function(path, startMs, forceImmediate)
  local isCrossfadeOn = (prefs.getInt("pref_crossfade", 1) == 1)
  local canCrossfade = not forceImmediate and isPlaying and mediaPlayer and (not startMs or startMs == 0) and isCrossfadeOn

  if canCrossfade then
    local isStillPlaying = false
    pcall(function() isStillPlaying = mediaPlayer.isPlaying() end)
    if isStillPlaying then
      if isCrossfading then
        finishCrossfadeImmediately()
      end
      local cDur = getCrossfadeDurMs()
      startCrossfadeTo(path, currentIndex, cDur)
      return
    end
  end

  pcall(function()
    if nextMediaPlayer then
      pcall(function() nextMediaPlayer.release() end)
      nextMediaPlayer = nil
    end

    for _, p in ipairs(fadingOldPlayers) do
      pcall(function() p.stop(); p.release() end)
    end
    fadingOldPlayers = {}

    if mediaPlayer then
      pcall(function() mediaPlayer.stop(); mediaPlayer.release() end)
      mediaPlayer = nil
      sysProps.remove("GLOBAL_ADV_MEDIA_PLAYER")
    end

    mediaPlayer = MediaPlayer()
    mediaPlayer.setDataSource(path)
    mediaPlayer.prepare()

    if startMs and startMs > 0 then
      pcall(function() mediaPlayer.seekTo(startMs) end)
    end

    local maxV = getCurrentMaxVolume()
    mediaPlayer.setVolume(maxV, maxV)
    mediaPlayer.start()
    isPlaying = true
    isCrossfading = false
    if btnPlay then btnPlay.setText("JEDA") end

    isLoopingAB = false
    loopA = 0
    loopB = 0

    pcall(function()
      if audioManager and audioFocusListener then
        audioManager.requestAudioFocus(audioFocusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
      end
    end)

    currentSongPath = path
    local f = File(path)
    if txtSongTitle then txtSongTitle.setText(f.getName()) end
    if txtFolderInfo then txtFolderInfo.setText("Folder: " .. currentFolderName) end

    sysProps.put("GLOBAL_ADV_MEDIA_PLAYER", mediaPlayer)
    sysProps.put("GLOBAL_ADV_SONG_PATH", path)
    sysProps.put("GLOBAL_ADV_SONG_INDEX", tostring(currentIndex))

    local ed = prefs.edit()
    ed.putString("last_played_path", path)
    if startMs and startMs > 0 then
      ed.putInt("last_played_pos", startMs)
    else
      ed.putInt("last_played_pos", 0)
    end
    ed.apply()

    applyPitchAndSpeed()
    pcall(function() applyAudioEffects(mediaPlayer.getAudioSessionId()) end)
    applySleepTimer()
    applyVolumeDucking()
    attachCompletionListener(mediaPlayer)
    prepareNextTrackGapless()
  end)
end

-- Listener Geser Durasi (SeekBar)
pcall(function()
  local SeekBarChangeListener = luajava.bindClass("android.widget.SeekBar$OnSeekBarChangeListener")
  sbProgress.setOnSeekBarChangeListener(SeekBarChangeListener{
    onProgressChanged = function(sb, progress, fromUser)
      if fromUser and mediaPlayer then
        pcall(function()
          local dur = mediaPlayer.getDuration()
          if dur > 0 then
            local targetMs = math.floor((progress / 100) * dur)
            mediaPlayer.seekTo(targetMs)
            txtTimer.setText(formatTime(targetMs) .. " / " .. formatTime(dur))
          end
        end)
      end
    end,
    onStartTrackingTouch = function(sb)
      isUserSeeking = true
    end,
    onStopTrackingTouch = function(sb)
      isUserSeeking = false
      pcall(function()
        if mediaPlayer then
          local dur = mediaPlayer.getDuration()
          if dur > 0 then
            local targetMs = math.floor((sb.getProgress() / 100) * dur)
            mediaPlayer.seekTo(targetMs)
            prefs.edit().putInt("last_played_pos", targetMs).apply()
            service.speak("Posisi " .. sb.getProgress() .. "% (" .. formatTime(targetMs) .. ")")
          end
        end
      end)
    end
  })
end)

-- Pembaruan Tampilan Real-Time & Pemicu Otomatis Pergantian Tanpa Jeda
local isDialogActive = true
local updateTimerRunnable = nil
updateTimerRunnable = Runnable{
  run = function()
    pcall(function()
      if not isServiceRunning then return end
      if mediaPlayer and mediaPlayer.isPlaying() then
        local pos = mediaPlayer.getCurrentPosition()
        local dur = mediaPlayer.getDuration()

        if isDialogActive and mainDialog and mainDialog.isShowing() then
          pcall(function()
            txtTimer.setText(formatTime(pos) .. " / " .. formatTime(dur))
            if not isUserSeeking and dur > 0 then
              sbProgress.setProgress(math.floor((pos * 100) / dur))
            end
          end)
        end

        local isCrossfadeOn = (prefs.getInt("pref_crossfade", 1) == 1)
        if isCrossfadeOn and not isCrossfading and not isUserSeeking and dur > 0 then
          local cDur = getCrossfadeDurMs()
          local effectiveDur = cDur
          if dur < (cDur * 2) then
            effectiveDur = math.max(1000, math.floor(dur / 3))
          end

          if (dur - pos <= effectiveDur) then
            local nextIdx = getNextTrackIndex()
            if nextIdx > 0 and filteredSongs[nextIdx] then
              startCrossfadeTo(filteredSongs[nextIdx], nextIdx, effectiveDur)
            end
          end
        end

        if not isUserSeeking and pos > 1000 and (dur - pos > 1500) then
          prefs.edit().putInt("last_played_pos", pos).apply()
        end

        if isLoopingAB and loopB > loopA and pos >= loopB then
          mediaPlayer.seekTo(loopA)
        end

        if Build.VERSION.SDK_INT >= 24 and audioManager then
          local isDuckingEnabled = (prefs.getInt("pref_ducking", 0) == 1)
          if isDuckingEnabled then
            local configs = audioManager.getActiveRecordingConfigurations()
            local isRec = (configs and configs.size() > 0)
            if isRec ~= isRecordingDucked then
              isRecordingDucked = isRec
              applyVolumeDucking()
            end
          elseif isRecordingDucked then
            isRecordingDucked = false
            applyVolumeDucking()
          end
        end
      end
    end)
    if isServiceRunning then
      mainHandler.postDelayed(updateTimerRunnable, 500)
    end
  end
}
mainHandler.post(updateTimerRunnable)

local function syncRunningPlayer()
  pcall(function()
    if mediaPlayer then
      if mediaPlayer.isPlaying() then
        isPlaying = true
        btnPlay.setText("JEDA")
        isSleepTimerArmed = true
      else
        isPlaying = false
        btnPlay.setText("PUTAR")
      end
      if currentSongPath ~= "" then
        txtSongTitle.setText(File(currentSongPath).getName())
        txtFolderInfo.setText("Folder: " .. currentFolderName)
      end
      attachCompletionListener(mediaPlayer)
      pcall(function() applyAudioEffects(mediaPlayer.getAudioSessionId()) end)
      pcall(function() applyPitchAndSpeed() end)
      prepareNextTrackGapless()
      applyVolumeDucking()
    end
  end)
end

-- ============================================================================
-- PENANGAN KLIK KONTROL UTAMA
-- ============================================================================
btnPlay.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    if not mediaPlayer then
      -- Bawaan resume sekarang dimatikan (default 0)
      local isResumeActive = (prefs.getInt("pref_resume", 0) == 1)
      local lastPath = prefs.getString("last_played_path", "")
      local lastPos = prefs.getInt("last_played_pos", 0)

      if isResumeActive and lastPath ~= "" and File(lastPath).exists() then
        local foundIdx = 1
        for idx, p in ipairs(filteredSongs) do
          if p == lastPath then foundIdx = idx; break end
        end
        currentIndex = foundIdx
        playTrack(lastPath, lastPos, true)
        if lastPos > 0 then
          pcall(function() service.speak("Melanjutkan lagu dari posisi " .. formatTime(lastPos)) end)
        end
      elseif #filteredSongs > 0 then
        currentIndex = 1
        playTrack(filteredSongs[currentIndex], 0, true)
      else
        pcall(function() service.speak("Daftar lagu kosong. Pindai musik terlebih dahulu.") end)
      end
      return
    end

    if mediaPlayer.isPlaying() then
      mediaPlayer.pause()
      btnPlay.setText("PUTAR")
      isPlaying = false
      pcall(function()
        prefs.edit().putInt("last_played_pos", mediaPlayer.getCurrentPosition()).apply()
        if audioManager and audioFocusListener then
          audioManager.abandonAudioFocus(audioFocusListener)
        end
        service.speak("Musik dijeda.")
      end)
    else
      mediaPlayer.start()
      btnPlay.setText("JEDA")
      isPlaying = true
      pcall(function()
        if audioManager and audioFocusListener then
          audioManager.requestAudioFocus(audioFocusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        end
        applyVolumeDucking()
        service.speak("Musik dilanjutkan.")
      end)
    end
  end
})

btnPrev.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    if #filteredSongs > 0 and currentIndex > 1 then
      currentIndex = currentIndex - 1
      playTrack(filteredSongs[currentIndex], 0)
    end
  end
})

btnNext.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    local nIdx = getNextTrackIndex()
    if nIdx > 0 and filteredSongs[nIdx] then
      currentIndex = nIdx
      playTrack(filteredSongs[currentIndex], 0)
    end
  end
})

btnRewind.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    pcall(function()
      if mediaPlayer then
        local step = getSeekStepMs()
        local p = math.max(0, mediaPlayer.getCurrentPosition() - step)
        mediaPlayer.seekTo(p)
        prefs.edit().putInt("last_played_pos", p).apply()
      end
    end)
  end
})

btnForward.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    pcall(function()
      if mediaPlayer then
        local step = getSeekStepMs()
        local p = math.min(mediaPlayer.getDuration(), mediaPlayer.getCurrentPosition() + step)
        mediaPlayer.seekTo(p)
        prefs.edit().putInt("last_played_pos", p).apply()
      end
    end)
  end
})

-- Dialog Pemilih Folder
local function openFolderDialog()
  if #folderList == 0 then
    pcall(function() service.speak("Belum ada folder lagu ditemukan. Silakan pindai.") end)
    return
  end

  local folderNames = {}
  table.insert(folderNames, "Semua Folder (" .. #songList .. " lagu)")
  for _, f in ipairs(folderList) do
    table.insert(folderNames, f.name .. " (" .. #f.songs .. " lagu)")
  end

  local b = AlertDialog.Builder(service)
  b.setTitle("Pilih Folder Musik")
  b.setItems(folderNames, DialogInterface.OnClickListener{
    onClick = function(d, which)
      if which == 0 then
        filteredSongs = songList
        currentFolderPath = ""
        currentFolderName = "Semua Folder"
        local ed = prefs.edit()
        ed.putString("last_folder_path", "")
        ed.putString("last_folder_name", "Semua Folder")
        ed.apply()
        txtFolderInfo.setText("Folder: Semua Folder")
        pcall(function() service.speak("Memilih semua folder (" .. #songList .. " lagu).") end)
      else
        local selFolder = folderList[which]
        local songNamesInFolder = {"► Putar Seluruh Folder Ini"}
        for i, s in ipairs(selFolder.songs) do
          table.insert(songNamesInFolder, i .. ". " .. File(s).getName())
        end

        local bSub = AlertDialog.Builder(service)
        bSub.setTitle(selFolder.name .. " (" .. #selFolder.songs .. " lagu)")
        bSub.setItems(songNamesInFolder, DialogInterface.OnClickListener{
          onClick = function(d2, whichSub)
            filteredSongs = selFolder.songs
            currentFolderPath = selFolder.path
            currentFolderName = selFolder.name
            local ed = prefs.edit()
            ed.putString("last_folder_path", selFolder.path)
            ed.putString("last_folder_name", selFolder.name)
            ed.apply()
            txtFolderInfo.setText("Folder: " .. currentFolderName)
            if whichSub == 0 then
              currentIndex = 1
              playTrack(filteredSongs[1], 0)
            else
              currentIndex = whichSub
              playTrack(filteredSongs[currentIndex], 0)
            end
          end
        })
        bSub.setNegativeButton("Kembali", nil)
        local dlgSub = bSub.create()
        dlgSub.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
        dlgSub.show()
      end
    end
  })
  b.setNegativeButton("Batal", nil)
  local dlg = b.create()
  dlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
  dlg.show()
end

btnFolders.setOnClickListener(View.OnClickListener{ onClick = function(v) openFolderDialog() end })

btnSongList.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    if #filteredSongs == 0 then
      pcall(function() service.speak("Daftar lagu kosong. Pindai terlebih dahulu.") end)
      return
    end
    local titles = {}
    for i, p in ipairs(filteredSongs) do
      table.insert(titles, i .. ". " .. File(p).getName())
    end
    local b = AlertDialog.Builder(service)
    b.setTitle("Daftar: " .. currentFolderName .. " (" .. #filteredSongs .. ")")
    b.setItems(titles, DialogInterface.OnClickListener{
      onClick = function(d, which)
        currentIndex = which + 1
        playTrack(filteredSongs[currentIndex], 0)
      end
    })
    b.setNegativeButton("Tutup", nil)
    local dlg = b.create()
    dlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
    dlg.show()
  end
})

btnSearch.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    local edit = EditText(service)
    edit.setHint("Ketik nama lagu...")
    local b = AlertDialog.Builder(service)
    b.setTitle("Cari Musik")
    b.setView(edit)
    b.setPositiveButton("Cari", DialogInterface.OnClickListener{
      onClick = function(d, w)
        local query = tostring(edit.getText()):lower():gsub("%s+", "")
        if query == "" then return end
        filteredSongs = {}
        for _, p in ipairs(songList) do
          if File(p).getName():lower():find(query, 1, true) then
            table.insert(filteredSongs, p)
          end
        end
        currentFolderPath = "SEARCH"
        currentFolderName = "Hasil Cari (" .. query .. ")"
        txtFolderInfo.setText("Folder: " .. currentFolderName)
        pcall(function() service.speak("Ditemukan " .. #filteredSongs .. " hasil.") end)
      end
    })
    b.setNegativeButton("Batal", nil)
    local dlg = b.create()
    dlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
    dlg.show()
  end
})

btnClear.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    filteredSongs = songList
    currentFolderPath = ""
    currentFolderName = "Semua Lagu"
    local ed = prefs.edit()
    ed.putString("last_folder_path", "")
    ed.putString("last_folder_name", "Semua Lagu")
    ed.apply()
    txtFolderInfo.setText("Folder: Semua Lagu")
    pcall(function() service.speak("Menampilkan seluruh lagu.") end)
  end
})

btnFav.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    if currentIndex > 0 and filteredSongs[currentIndex] then
      local path = filteredSongs[currentIndex]
      local currentFavs = prefs.getString("favorite_songs", "")
      local alreadyFav = false
      for line in currentFavs:gmatch("[^\r\n]+") do
        if line == path then
          alreadyFav = true
          break
        end
      end
      if not alreadyFav then
        prefs.edit().putString("favorite_songs", currentFavs .. path .. "\n").apply()
        pcall(function() service.speak("Lagu dimasukkan ke Favorit.") end)
      else
        pcall(function() service.speak("Lagu sudah ada di Favorit.") end)
      end
    end
  end
})

btnLibrary.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    local options = {"Pilih dari Folder", "Lagu Terakhir Diputar", "Daftar Favorit"}
    local b = AlertDialog.Builder(service)
    b.setTitle("Pustaka Audio")
    b.setItems(options, DialogInterface.OnClickListener{
      onClick = function(d, which)
        if which == 0 then
          openFolderDialog()
        elseif which == 1 then
          local last = prefs.getString("last_played_path", "")
          local lastPos = prefs.getInt("last_played_pos", 0)
          if last ~= "" and File(last).exists() then
            playTrack(last, lastPos, true)
            if lastPos > 0 then
              pcall(function() service.speak("Melanjutkan dari posisi " .. formatTime(lastPos)) end)
            end
          else
            pcall(function() service.speak("Tidak ada data lagu terakhir.") end)
          end
        elseif which == 2 then
          local favsRaw = prefs.getString("favorite_songs", "")
          local favList = {}
          for line in favsRaw:gmatch("[^\r\n]+") do
            if File(line).exists() then table.insert(favList, line) end
          end
          if #favList == 0 then
            pcall(function() service.speak("Daftar favorit kosong.") end)
            return
          end
          local favNames = {}
          for idx, p in ipairs(favList) do table.insert(favNames, idx .. ". " .. File(p).getName()) end
          local bFav = AlertDialog.Builder(service)
          bFav.setTitle("Lagu Favorit (tekan lama untuk hapus)")
          bFav.setItems(favNames, DialogInterface.OnClickListener{
            onClick = function(d2, w2)
              filteredSongs = favList
              currentIndex = w2 + 1
              currentFolderPath = "FAVORITES"
              currentFolderName = "Favorit"
              txtFolderInfo.setText("Folder: Favorit")
              playTrack(filteredSongs[currentIndex], 0)
            end
          })
          local dlgFav = bFav.create()
          dlgFav.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)

          pcall(function()
            dlgFav.getListView().setOnItemLongClickListener(luajava.bindClass("android.widget.AdapterView$OnItemLongClickListener"){
              onItemLongClick = function(parent, itemView, position, id)
                local removedPath = favList[position + 1]
                if removedPath then
                  local newFavsRaw = ""
                  for _, p in ipairs(favList) do
                    if p ~= removedPath then
                      newFavsRaw = newFavsRaw .. p .. "\n"
                    end
                  end
                  prefs.edit().putString("favorite_songs", newFavsRaw).apply()
                  pcall(function() service.speak("Dihapus dari Favorit: " .. File(removedPath).getName()) end)
                  dlgFav.dismiss()
                end
                return true
              end
            })
          end)

          dlgFav.show()
        end
      end
    })
    local dlg = b.create()
    dlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
    dlg.show()
  end
})

btnRescan.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    pcall(function() service.speak("Memindai berkas audio...") end)
    Thread(Runnable{
      run = function()
        performScan(false)
      end
    }).start()
  end
})

btnSettings.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    showSettingsDialog(function()
      refreshButtonLabels()
      applySleepTimer()
      updateRepeatButtonUI()
      prepareNextTrackGapless()
      applyVolumeDucking()
      reapplyEffectSettings()
    end, txtFolderInfo, txtSongTitle)
  end
})

btnBackground.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    isDialogActive = false
    mainDialog.dismiss()
    pcall(function() service.speak("Pemutar diminimalkan ke latar belakang. Musik tetap berputar.") end)
  end
})

btnExit.setOnClickListener(View.OnClickListener{
  onClick = function(v)
    isServiceRunning = false
    isDialogActive = false
    if updateTimerRunnable then
      mainHandler.removeCallbacks(updateTimerRunnable)
    end
    pcall(function()
      if audioManager and audioFocusListener then
        audioManager.abandonAudioFocus(audioFocusListener)
      end
      if nextMediaPlayer then
        pcall(function() nextMediaPlayer.release() end)
        nextMediaPlayer = nil
      end
      for _, p in ipairs(fadingOldPlayers) do
        pcall(function() p.stop(); p.release() end)
      end
      fadingOldPlayers = {}
      if mediaPlayer then
        prefs.edit().putInt("last_played_pos", mediaPlayer.getCurrentPosition()).apply()
        mediaPlayer.stop()
        mediaPlayer.release()
        mediaPlayer = nil
      end
      sysProps.remove("GLOBAL_ADV_MEDIA_PLAYER")
      sysProps.remove("GLOBAL_ADV_SONG_PATH")
      sysProps.remove("GLOBAL_ADV_SONG_INDEX")
      sysProps.remove("GLOBAL_ADV_NEXT_INDEX")
      cancelSleepTimer()
      releaseAudioEffects()
      service.speak("Pemutar musik dihentikan dan ditutup.")
    end)
    mainDialog.dismiss()
  end
})

-- Sinkronisasi status player yang sedang aktif
syncRunningPlayer()

-- Jalankan pemindaian audio di latar belakang tanpa mengganggu respon antarmuka
Thread(Runnable{
  run = function()
    performScan(true)
  end
}).start()
