 Okay, here's how you solve wren. So the problem right now is that I have tail scale set up And so what I'm doing is I'm bouncing around between machines constantly I have The MacBook Pro It's kind of a server I keep it plugged in And sometimes I hook into it On the 4K monitor with the ZKS Voyager And so that's not a default keyboard @ the change You know, I got whatever dictation doesn't matter every every terminal. I have I have a terminal that connects to my MacBook Pro. That's like the main server And I can bring it with me if I need So it unplugs, it's portable It's great, but I still have my M1 Air My M1 Air is my.. portable terminal I can bring it with me anywhere. I could pop it into my bag Oh, you know, fuck what happens to it. It's years old. Got good battery 8 gigs of RAM, it's light as fuck.  Then My upstairs terminal I got 2 machines on 1 computer, 2 operating systems on 1 computer Windows for gaming with alacrity and WSL or just PowerShell SSH into MacBook Pro PQ9 is what the Mac and Pro is called Then I'll not, on that same gaming computer, I also have my arch blocks It's called AV And so both of those are just SSH into MacBook Pro And it's great Because it doesn't matter which ones up both get access to the same dev environment. So I got 3 machines or like 2 and a half Plus a potential phone, which I'm trying to figure out I'm gonna figure out a super mobile device But tail scale makes all this possible, right? So the idea is like.. If I can dictate on edge Like the Otis program I'm working on Works great on the M1 Air. It's like the minimum target spec and it works great So if dictation is on edge But that wouldn't make sense for Wren. Wren  makes more sense as something that is generating voice from 1 place Meaning It is running on 1 server And it has several clients That connect to it So we have a form of this already because we are working on the daemon But what we've decided is that the daemon controls The spawning of the server What we should actually do is decouple it so that the server can be on Let's say I put it on 8GB GPU put it on the box literal box computer. That's my fourth computerby the way Too many fucking computers  So the idea right now is that The server can't be the thing that's playing back the audio, right? The client has to be the thing that's playing back the audio. When we can set that up, we just make the daemon Hit some fucking port and IP And you can choose where that spawns, I don't know I don't know how to make that into a real program, but I know how to make it into a program for myself that I can control easily And so what I want is to have dictation on edge and playback on edge. So that means that I can use This current laptop that I'm on, the M1 Air and I can talk to an agent the SSH on the Mac Pro But then when it uses "ren",That gets piped out, that gets sent out to the current client that I'm on.

filter out speakers to real speakers only
effect and launch in login text flicker on every opening of the menu bar
can't click on added voices in voice settings menu
switching voices dont work

I fear this went from slop to poob
the UI is good at least but wtf is this serve.py script 
im gonna be sick
this architecture is so ass
these bots they just poob everywheere all over your codebase when they dont undersstand anything.

the whole point of this refactor was to fix voice changing and it didnt work.

daemon of course persists its setting and works if you restart it

does the effect toggle work?
