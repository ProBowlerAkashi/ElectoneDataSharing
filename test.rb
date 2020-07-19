require 'digest/sha2'
require 'active_record'
require 'sinatra'
require 'fileutils'
require 'zip'

set :environment, :production

set :sessions,
  secret: 'xxx'

ActiveRecord::Base.configurations = YAML.load_file('database.yml')
ActiveRecord::Base.establish_connection :development

class Account < ActiveRecord::Base
end

class Smkfile < ActiveRecord::Base
end

class Dllog < ActiveRecord::Base
end

class ZipFileGenerator
  # Initialize with the directory to zip and the location of the output archive.
  def initialize(input_dir, output_file)
    @input_dir = input_dir
    @output_file = output_file
  end

  # Zip the input directory.
  def write
    entries = Dir.entries(@input_dir) - %w(. ..)

    ::Zip::File.open(@output_file, ::Zip::File::CREATE) do |zipfile|
      write_entries entries, '', zipfile
    end
  end

  private

  # A helper method to make the recursion work.
  def write_entries(entries, path, zipfile)
    entries.each do |e|
      zipfile_path = path == '' ? e : File.join(path, e)
      disk_file_path = File.join(@input_dir, zipfile_path)
      puts "Deflating #{disk_file_path}"

      if File.directory? disk_file_path
        recursively_deflate_directory(disk_file_path, zipfile, zipfile_path)
      else
        put_into_archive(disk_file_path, zipfile, zipfile_path)
      end
    end
  end

  def recursively_deflate_directory(disk_file_path, zipfile, zipfile_path)
    puts zipfile_path
    zipfile.mkdir zipfile_path
    subdir = Dir.entries(disk_file_path) - %w(. ..)
    write_entries subdir, zipfile_path, zipfile
  end

  def put_into_archive(disk_file_path, zipfile, zipfile_path)
    zipfile.get_output_stream(zipfile_path) do |f|
      f.write(File.open(disk_file_path, 'rb').read)
    end
  end
end

get '/' do
  puts "hello"
  if session[:login_flag] == true
    redirect '/index'
  else
    session[:failure] = false
    redirect '/login'
  end
end

get '/login' do
  puts session[:failure]
  @log = session[:failure]
  erb :loginscr
end 

post '/auth' do
  username = params[:user]
  userpass = params[:pass]

  #Log in
  begin
    current_acc = Account.find(username)
  rescue => err_obj
    puts "account nf"
    redirect '/failure'
  end
  
  if current_acc.algo == "1" #MD5 sum
    passwd_hashed = Digest::MD5.hexdigest(current_acc.salt + userpass)
  elsif current_acc.algo == "2" #SHA256 sum
    passwd_hashed = Digest::SHA256.hexdigest(current_acc.salt + userpass)
  else #unknown
    puts "Err...Unknown algorythm was used to hash the passwd"
    exit(-2)
  end
  
  puts "passwd_hashed = " + passwd_hashed
  puts "current_acc.hashed = " + current_acc.hashed

  if passwd_hashed == current_acc.hashed
    #Log in succeed
    session[:login_flag] = true
    session[:userid] = current_acc.id
    session[:failure] = false
    redirect '/'
  else
    #Log in failure
    session[:login_flag] = false
    redirect '/failure'
  end
end

get '/failure' do
  #login failure
  session[:login_flag] = false
  session[:failure] = true
  redirect '/login'
end

get '/logout' do
  #Log out
  session.clear
  erb :logout
end

get '/register' do
  #sign up
  erb :registerscr  
end

post '/signup' do
  #new user addition
  begin #User id was already used
    n = Account.find(params[:nuser])
  rescue #User id is not used
    session[:userexist] = false
    n = Account.new
    password = params[:npass]
    str = [('a'..'z'), ('A'..'Z'), ('0'..'9')].map { |i| i.to_a }.flatten
    n.id = params[:nuser]
    n.salt = (0...40).map { str[rand(str.length)] }.join
    n.hashed = Digest::SHA256.hexdigest(n.salt + password)
    n.algo = "2"
    n.save
    session[:login_flag] = false
    redirect '/signed'
  end
  session[:userexist] = true
  redirect 'register'
end

get '/signed' do
  #sign up succeed
  erb :signed
end

get '/index' do
  redirect '/' if session[:login_flag] == false
  
  images = Smkfile.last(20)
  logs = Dllog.where("userid = ?", session[:userid])[0..5]
  if images != nil
    @image = []
    images.each do |a|
      @image << a
    end
  end
  if logs != nil
    @log = []
    logs.each do |a|
      @log << Smkfile.find(a.fileid)
    end
  end
  erb :index
end

post '/search' do
  redirect '/' if session[:login_flag] == false
  @str = params[:str]
  puts @str
  images = Smkfile.where("name = ?",@str)
  if images != nil
    @image = []
    images.each do |a|
      @image << a
    end
  end
  
  erb :search
end

post '/download/:filename' do
  #request Download
  begin 
    @a = Smkfile.find(params[:filename])
  rescue
    redirect '/'
  end
  b = Dllog.new
  b.userid = session[:userid]
  b.fileid = @a.id
  b.date = Time.now
  b.save
  erb :download
end

get '/upload' do  
  redirect '/' if session[:login_flag] == false
  #request Upload
  erb :upload
end

post '/execupload' do
  redirect '/' if session[:login_flag] == false
  #Upload files
  s = params[:b00file]
  t = params[:namfile]
  filedir = "./public/files/#{params[:filename]}"
  filedir.gsub!(/( )/,"_")
  if s!= nil or t != nil
    begin
      FileUtils.mkdir(filedir)
    rescue
      session[:fileexist] == true
      redirect '/upload'
    end
    FileUtils.mkdir("./public/files/#{params[:filename]}/SONG_001".gsub!(/( )/,"_"))
    save_path = "./public/files/#{params[:filename]}/#{params[:namfile][:filename]}"
    File.open(save_path.gsub!(/( )/,"_"), "wb") do |f|
      g = params[:namfile][:tempfile]
      f.write g.read
    end
    save_path = "./public/files/#{params[:filename]}/SONG_001/#{params[:b00file][:filename]}"
    File.open(save_path.gsub!(/( )/,"_"), "wb") do |f|
      g = params[:b00file][:tempfile]
      f.write g.read
    end
    #Zip files to download
    zipdir = "./public/files/#{params[:filename]}"
    zipfile = "./public/files/DL_#{params[:filename]}.zip"
    zipdir.gsub!(/( )/,"_")
    zipfile.gsub!(/( )/,"_")

    zipgen = ZipFileGenerator.new(zipdir,zipfile)
    zipgen.write  

    h = Smkfile.new
    h.name = params[:filename].gsub!(/( )/,"_")
    h.auther = session[:userid]
    h.save
    session[:uploaderr]=false
  else
    puts "Upload failed"
    session[:uploaderr]=true
    redirect '/upload'
  end
  redirect '/index'
end

post '/main' do
  redirect '/'
end
