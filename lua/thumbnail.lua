
local c = require 'config'

--[[
	ngx_uri           :链接地址，如/goods/0007/541/001_328x328.jpg
	ngx_img_root      :图片根目录
	ngx_thumbnail_root:缩略图根目录
	img_width         :缩略图宽度
	img_width         :缩略图高度
	img_size          :缩略图宽x高
	img_crop_type     :缩略图裁剪类型
	cur_uri_reg_model :缩略图uri正则规则
	img_original_uri  :原图地址
	img_thumbnail_path:缩略图目录
]]
local ngx_uri = ngx.var.uri
local ngx_img_root = ngx.var.image_root
local ngx_thumbnail_root = ngx.var.thumbnail_root
local img_width,img_height,img_size,img_crop_type = 0
local cur_uri_reg = c.default_uri_reg
local img_original_uri = string.gsub(ngx_uri, cur_uri_reg, '')
local img_original_path  = ngx_img_root .. img_original_uri
local img_thumbnail_path = ngx_thumbnail_root .. ngx_uri

-- 日志函数 默认为ngx.NOTICE 取值范围：ngx.STDERR , ngx.EMERG , ngx.ALERT , ngx.CRIT , ngx.ERR , ngx.WARN , ngx.NOTICE , ngx.INFO , ngx.DEBUG
function lua_log(msg,log_level)
	log_level = log_level or c.lua_log_level
    if (c.enabled_log) then
		ngx.log(log_level,msg)
	end
end

--	匹配链接对应缩略图规则
function table.contains(table, element)
	img_crop_type = 0
    for _, value in pairs(c.cfg) do
        local dir = value['dir']
        local sizes = value['sizes']
		local uri_reg = value['uri_reg']
        _,_,img_width,img_height = string.find(element, ''.. dir ..'+.*_([0-9]+)x([0-9]+)')
        if(img_width and img_height and img_crop_type==0) then
            img_size = img_width..'x'..img_height
            for _, value in pairs(sizes) do
				cur_uri_reg = uri_reg or cur_uri_reg
                if (img_size == value) then
                    img_crop_type=1
                    return true
                elseif (img_size..'_' == value) then
                    img_crop_type=2
                    return true
                elseif (img_size..'!' == value) then
                    img_crop_type=3
                    return true
                elseif (img_size..'^' == value) then
                    img_crop_type=4
                    return true
                elseif (img_size..'>' == value) then
                    img_crop_type=5
                    return true
                elseif (img_size..'$' == value) then
                    img_crop_type=6
                    img_size = img_width..'x'
                    return true
                end
            end
        end
    end
    return false
end

-- 拼接gm命令
local function generate_gm_command(img_crop_type,img_original_path,img_size,img_thumbnail_path)
	local cmd = c.gm_path .. ' convert ' .. img_original_path
	if (img_crop_type == 1) then
		cmd = cmd .. ' -thumbnail '  .. img_size .. ' -background ' .. c.img_background_color .. ' -gravity center -extent ' .. img_size
	elseif (img_crop_type == 2) then
		cmd = cmd .. ' -thumbnail '  .. img_size
	elseif (img_crop_type == 3) then
		cmd = cmd .. ' -thumbnail "'  .. img_size .. '!" -extent ' .. img_size
	elseif (img_crop_type == 4) then
		cmd = cmd .. ' -thumbnail "'  .. img_size .. '^" -extent ' .. img_size
	elseif (img_crop_type == 5 or img_crop_type == 6) then
		cmd = cmd .. ' -resize "'  .. img_size .. '>"'
	else
		lua_log('img_crop_type error:'..img_crop_type,ngx.ERR)
		ngx.exit(404)
	end
	cmd = cmd .. ' ' .. img_thumbnail_path
	return cmd
end

-- 写入文件
local function writefile(filename, info)
    local wfile = assert(io.open(filename, "w"))
    if wfile ~= nil then
    	wfile:write(info)
    	wfile:close()
    end
end

local function fdfskey(uri)
	local _,_,dir,filename = string.find(uri,'(.-)([^/]*)$')
	filename = string.gsub(filename, "(-)", "/")
	return filename
end

local function getfdfs(config, fileid)
    -- local fileid = string.sub(fileid, 2)
    local fastdfs = require('fastdfs')
    local fdfs = fastdfs:new()
    lua_log('fdfs: ' .. config.host .. ':' .. config.port .. ':' .. fileid)
    fdfs:set_tracker(config.host, config.port)
    fdfs:set_timeout(config.timeout)
    fdfs:set_tracker_keepalive(0, 100)
    fdfs:set_storage_keepalive(0, 100)
    local data = fdfs:do_download(fileid)
    return data
end

-- 获取文件方法
local getfile = {
	['socket'] = function (config, path, uri)
		local img_exist = io.open(path .. uri)
		if not img_exist then
			local key = fdfskey(uri)
            local i = 1
            if config.poll then
                math.randomseed(os.time())
                i = math.random(table.getn(config.connections))
            end
            local data = getfdfs(config.connections[i], key)
            if not data then
            	data = getfdfs(config.connections[2], key)
            end
            lua_log('img:' .. data)
		    if data then
                local _,_,dir,filename = string.find(path .. uri,'(.-)([^/]*)$')
		        os.execute("mkdir -p " .. dir)
		        writefile(path .. uri, data)
		    end
		end
	end,
	['http'] = function (config, path, uri)
		local img_exist = io.open(path .. uri)
		if not img_exist then
			local _,_,dir,filename = string.find(path..uri,'(.-)([^/]*)$')
			local key = fdfskey(uri)
			local cmd = 'wget -T '..config.timeout..' -O '.. path .. uri ..' '..config.url..'/'..key
		    os.execute("mkdir -p " .. dir)
		    os.execute(cmd)
		    lua_log('get:'..cmd)
		end
	end,
}

-- 获取远程文件
getfile[c.remote_driver](c.remote_channel[c.remote_driver], ngx_img_root, img_original_uri)

if table.contains(c.cfg, ngx_uri) then
    lua_log('cur_uri_reg==='.. cur_uri_reg .. ',img_crop_type===' .. img_crop_type .. ',img_size===' .. img_size)
    local img_exist = io.open(img_original_path)
    if (not img_exist and c.enabled_default_img) then
		img_exist = io.open(ngx_img_root .. c.default_img_uri)
		if img_exist then
			lua_log(img_original_uri .. ' is not exist! crop image with default image')
			img_original_path = ngx_img_root .. c.default_img_uri
			ngx_uri = c.default_img_uri .. '_' .. img_size ..  '.' .. img_original_path:match("%.(%w+)$")
			img_thumbnail_path = ngx_thumbnail_root .. ngx_uri
		else
			lua_log(c.default_img_uri .. ' is not exist!', ngx.ERR)
			ngx.exit(404)
		end
	end

    local gm_command = generate_gm_command(img_crop_type,img_original_path,img_size,img_thumbnail_path)
    if (gm_command) then
        _,_,img_thumbnail_dir,img__thumbnail_filename = string.find(img_thumbnail_path,'(.-)([^/]*)$')
        local cmd = os.execute('mkdir -p ' .. img_thumbnail_dir)
        cmd = os.execute(gm_command)
        lua_log('exec==='.. cmd)
    end
else
	lua_log(ngx_uri .. ' is not match!', ngx.ERR)
end

local img_exist = io.open(img_thumbnail_path);
if img_exist then
	ngx.req.set_uri('' .. ngx_uri)
else
	lua_log(ngx_uri .. ' is not exist!', ngx.ERR)
	ngx.exit(404)
end
