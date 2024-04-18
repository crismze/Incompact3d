!Copyright (c) 2012-2022, Xcompact3d
!This file is part of Xcompact3d (xcompact3d.com)
!SPDX-License-Identifier: BSD 3-Clause

module mhd
  !
  use decomp_2d_constants, only : mytype, real_type
  use decomp_2d_mpi, only : nrank,nproc
  use decomp_2d, only : xsize
  use mptool, only: psum,pmax,cross_product
  !
  implicit none
  !
  logical :: mhd_active
  logical :: mhd_equation
  real(8) :: hartmann,stuart,rem
  !+------------+------------------------------------------------------+
  !|  mhd_active| the swith to activate the mhd module.                |
  !|    hartmann| hartmann number, the ratio of lorentz force to       |
  !|            | viscous force                                        |
  !|      stuart| Stuart number, magnetic interaction parameter, ratio |
  !|            | of electromagnetic to inertial forces                |
  !+------------+------------------------------------------------------+
  !
  real(mytype),allocatable,dimension(:,:,:,:) :: Bmean
  real(mytype),allocatable,dimension(:,:,:,:) :: Bm,magelf,Je
  real(mytype),allocatable,dimension(:,:,:,:,:) :: dBm
  real(mytype),allocatable,dimension(:,:,:) :: elcpot
  !+------------+------------------------------------------------------+
  !|          Bm| magnetic field                                       |
  !|      magelf| Electromagnetic forced to apply to the momentum eq.  |
  !|      elcpot| electric potential                                   |
  !|          Je| electric field as the gradient of potential          |
  !+------------+------------------------------------------------------+
  !
  contains
  !
  !+-------------------------------------------------------------------+
  !| this subroutine is to initilise the MHD module.                   |
  !+-------------------------------------------------------------------+
  !| change record                                                     |
  !| -------------                                                     |
  !| 28-Oct-2022  | Created by J. Fang STFC Daresbury Laboratory       |
  !+-------------------------------------------------------------------+
  subroutine mhd_init
    !
    use param, only: re,ntime
    !
    ! stuart=hartmann**2/re
    !
    if(stuart<=1.d-15) then
      stuart=hartmann**2/re
    endif
    if(hartmann<=1.d-15) then
      hartmann=sqrt(stuart*re)
    endif
    !
    if(nrank==0) then
      !
      print*,'** MHD Module activated'
      print*,'**    MHD equation: ',mhd_equation
      print*,'** Hartmann number: ',hartmann
      print*,'**   Stuart number: ',stuart
      print*,'**              Re: ',re
      print*,'**     Magnetic Re: ',rem
      !
    endif
    !
    allocate( Bm(xsize(1),xsize(2),xsize(3),1:3),                  &
              magelf(xsize(1),xsize(2),xsize(3),1:3),              &
              Je(xsize(1),xsize(2),xsize(3),1:3),                  &
              elcpot(xsize(1),xsize(2),xsize(3)),                  &
              dBm(xsize(1),xsize(2),xsize(3),1:3,1:ntime) )
    !
    allocate(Bmean(xsize(1),xsize(2),xsize(3),1:3))
    !
    if(nrank==0) print*,'** MHD fields allocated'
    !
  end subroutine mhd_init
  !+-------------------------------------------------------------------+
  !| The end of the subroutine mhd_init.                               |
  !+-------------------------------------------------------------------+
  !
  subroutine int_time_magnet
    !
    USE param
    USE variables
    USE decomp_2d_mpi, only : decomp_2d_abort
    use ydiff_implicit

    implicit none
    !
    integer :: k

    if( iimplicit == 1 ) then
       call decomp_2d_abort(iimplicit, "MHD is not compatible with implicit diffusion")
    else
       if(itimescheme.eq.3) then
           !>>> Adams-Bashforth third order (AB3)

           ! Do first time step with Euler
           if(itime.eq.1.and.irestart.eq.0) then
              Bm=dt*dBm(:,:,:,:,1)+Bm
           elseif(itime.eq.2.and.irestart.eq.0) then
              ! Do second time step with AB2
              Bm=onepfive*dt*dBm(:,:,:,:,1)-half*dt*dBm(:,:,:,:,2)+Bm
              dBm(:,:,:,:,3)=dBm(:,:,:,:,2)
           else
              ! Finally using AB3
              Bm=adt(itr)*dBm(:,:,:,:,1)+bdt(itr)*dBm(:,:,:,:,2)+cdt(itr)*dBm(:,:,:,:,3)+Bm
              dBm(:,:,:,:,3)=dBm(:,:,:,:,2)
           endif
           dBm(:,:,:,:,2)=dBm(:,:,:,:,1)

        elseif(itimescheme.eq.5) then
          !
           if(itr.eq.1) then
              Bm=gdt(itr)*dBm(:,:,:,:,1)+Bm
           else
              Bm=adt(itr)*dBm(:,:,:,:,1)+bdt(itr)*dBm(:,:,:,:,2)+Bm
           endif
           dBm(:,:,:,:,2)=dBm(:,:,:,:,1)
           !
       else
          call decomp_2d_abort(itimescheme, "MHD is not compatible with selected time scheme")
       endif
   endif
    !
  end subroutine int_time_magnet
  !
  function vortcal(dux1,duy1,duz1) result(omega)
    !
    use param, only : ntime
    !
    real(mytype), dimension(xsize(1),xsize(2),xsize(3),ntime) :: dux1,duy1,duz1
    real(mytype), dimension(xsize(1),xsize(2),xsize(3)) :: omega
    !
    omega(:,:,:)=duy1(:,:,:,1)-dux1(:,:,:,2)
    !
  end function vortcal
  !
  !+-------------------------------------------------------------------+
  !| this subroutine is calculate and output statistics of MHD flow.   |
  !+-------------------------------------------------------------------+
  !| change record                                                     |
  !| -------------                                                     |
  !| 01-May-2023  | Created by J. Fang STFC Daresbury Laboratory       |
  !+-------------------------------------------------------------------+
  subroutine mhd_sta(ux1,uy1,uz1)
    !
    !use decomp_2d
    use param,     only : ntime,t,nclx1, ncly1, nclz1,re
    use var,       only : itime
    use variables, only : nx, ny, nz, nxm, nym, nzm
    use mptool,    only : pmax,psum
    !
    real(mytype), dimension(xsize(1),xsize(2),xsize(3)) :: ux1,uy1,uz1
    !
    ! local data
    real(mytype) :: Ek,Em,Omegam,Jmax,var1,var2,disrat
    logical,save :: lfirstcal=.true.
    integer,save :: iounit = 13
    integer,save :: nxc,nyc,nzc
    integer :: i,j,k
    !
    if(lfirstcal) then
      !
      if(nrank==0) then
        open(newunit=iounit,file='mhd_stat.dat')
        write(iounit,"(A7,1X,A13,5(1X,A20))")'itime','time',              &
                                'Ek','Em','enstrophykm','dissipation','Jmax'

      endif
      !
      if (nclx1==1) then
         nxc=nxm
      else
         nxc=nx
      endif
      if (ncly1==1) then
         nyc=nym
      else
         nyc=ny
      endif
      if (nclz1==1) then
         nzc=nzm
      else
         nzc=nz
      endif
      !
      lfirstcal=.false.
      !
    endif
    !
    Ek=0._mytype
    Em=0._mytype
    Omegam=0._mytype
    Jmax=0._mytype
    do k=1,xsize(3)
    do j=1,xsize(2)
    do i=1,xsize(1)
      
      var2=Je(i,j,k,1)**2+Je(i,j,k,2)**2+Je(i,j,k,3)**2

      Ek    =Ek    + ux1(i,j,k)**2+uy1(i,j,k)**2+uz1(i,j,k)**2
      Em    =Em    + Bm(i,j,k,1)**2+Bm(i,j,k,2)**2+Bm(i,j,k,3)**2
      Omegam=Omegam+ var2
      Jmax  = max(Jmax,var2)

    enddo
    enddo
    enddo
    !
    Ek    =psum(Ek    )
    Em    =psum(Em    )
    Omegam=psum(Omegam)
    Jmax  =pmax(Jmax)
    !
    Ek    =Ek    /real(nxc*nyc*nzc,mytype)/2._mytype
    Em    =Em    /real(nxc*nyc*nzc,mytype)/2._mytype
    Omegam=Omegam/real(nxc*nyc*nzc,mytype)/2._mytype*Rem*Rem
    Jmax  =sqrt(Jmax)*Rem
    !
    disrat=Ek/re+Em/rem
    ! print*,nxc,nyc,nzc
    !
    if(nrank==0) then
      write(iounit,"(I7,1X,E13.6E2,5(1X,E20.13E2))")itime,t,Ek,Em, &
                                            Omegam,disrat,Jmax
    endif
    !
  end subroutine mhd_sta
  !+-------------------------------------------------------------------+
  !| The end of the subroutine mhd_sta.                                |
  !+-------------------------------------------------------------------+
  !
  !+-------------------------------------------------------------------+
  !| this subroutine is used to add the electromagnetic force to the   |
  !| momentum equation                                                 |
  !+-------------------------------------------------------------------+
  !| change record                                                     |
  !| -------------                                                     |
  !| 28-Oct-2022  | Created by J. Fang STFC Daresbury Laboratory       |
  !+-------------------------------------------------------------------+
  subroutine momentum_forcing_mhd(dux1,duy1,duz1,ux1,uy1,uz1)
    !
    !USE decomp_2d
    use mpi
    use param,     only : dx,dz
    use variables, only : ppy
    use variables, only : yp,ny,nz
    use decomp_2d, only : xstart
    use constants, only : pi
    use param, only : zero,two,three,dy,yly
    !
    ! arguments
    real(mytype),intent(in),dimension(xsize(1),xsize(2),xsize(3)) ::   &
                                                ux1,uy1,uz1
    real(mytype),intent(inout),                                        &
                dimension(xsize(1),xsize(2),xsize(3)) ::  dux1,duy1,duz1
    !
    real(mytype) :: eforce(3),Ebar(3)
    real(mytype) :: ub,uball,coeff
    ! local data
    integer :: i,j,k,jloc,code
    real(mytype) :: elecur(3),var1(3),var2(3)
    !
    real(mytype) :: xx(xsize(1)),yy(xsize(2)),zz(xsize(3))
    !
    !
    
    if(mhd_equation) then
      Je=del_cross_prod(Bm+Bmean)/Rem
    else
      Je=solve_mhd_potential_poisson(ux1,uy1,uz1)
    endif
    !
    do k = 1, xsize(3)
    do j = 1, xsize(2)
    do i = 1, xsize(1)
      !
      eforce=cross_product(Je(i,j,k,:),Bm(i,j,k,:)+Bmean(i,j,k,:))*stuart
      !
      dux1(i,j,k) = dux1(i,j,k)+eforce(1)
      duy1(i,j,k) = duy1(i,j,k)+eforce(2)
      duz1(i,j,k) = duz1(i,j,k)+eforce(3)
      !
    enddo
    enddo
    enddo
    !
    !
  end subroutine momentum_forcing_mhd
  !+-------------------------------------------------------------------+
  !| The end of the subroutine momentum_forcing.                       |
  !+-------------------------------------------------------------------+
  !
  !+-------------------------------------------------------------------+
  !| this subroutine is used to calculate the result of ∇x.            |
  !+-------------------------------------------------------------------+
  !| change record                                                     |
  !| -------------                                                     |
  !| 28-Oct-2022  | Created by J. Fang STFC Daresbury Laboratory       |
  !+-------------------------------------------------------------------+
  function del_cross_prod(phi) result(delphi)
    !
    real(mytype) :: delphi(xsize(1),xsize(2),xsize(3),3)
    real(mytype),intent(in) :: phi(xsize(1),xsize(2),xsize(3),3)
    !
    real(mytype), dimension(xsize(1),xsize(2),xsize(3),3) :: dphi
    !
    dphi=grad_vmesh(phi(:,:,:,1))
    !
    delphi(:,:,:,2)= dphi(:,:,:,3)
    delphi(:,:,:,3)=-dphi(:,:,:,2)
    !
    dphi=grad_vmesh(phi(:,:,:,2))
    !
    delphi(:,:,:,1)=-dphi(:,:,:,3)
    delphi(:,:,:,3)= delphi(:,:,:,3) + dphi(:,:,:,1)
    !
    dphi=grad_vmesh(phi(:,:,:,3))
    !
    delphi(:,:,:,1)= delphi(:,:,:,1) + dphi(:,:,:,2)
    delphi(:,:,:,2)= delphi(:,:,:,2) - dphi(:,:,:,1)
    !
  end function del_cross_prod
  !+-------------------------------------------------------------------+
  !| The end of the function del_cross_prod.                           |
  !+-------------------------------------------------------------------+
  !
  !+-------------------------------------------------------------------+
  !| this subroutine is used to calculate the gradient of a general    |
  !| function on velocity mesh..................                       |
  !+-------------------------------------------------------------------+
  !| change record                                                     |
  !| -------------                                                     |
  !| 28-Oct-2022  | Created by J. Fang STFC Daresbury Laboratory       |
  !+-------------------------------------------------------------------+
  function grad_vmesh(phi) result(dphi)
    !
    use decomp_2d, only : ysize,zsize,transpose_x_to_y,                &
                          transpose_y_to_z,transpose_y_to_x,           &
                          transpose_z_to_y
    use variables, only: ffxpS,fsxpS,fwxpS,ffypS,fsypS,fwypS,ffzpS,    &
                         fszpS,fwzpS,ppy,sx,sy,sz,derxs,derys,derzs
    use param, only: zero
    use var, only : ta1,di1,ta2,di2,ta3,di3,td1,td2,td3,tg1
    !
    real(mytype) :: dphi(xsize(1),xsize(2),xsize(3),3)
    real(mytype),intent(in) :: phi(xsize(1),xsize(2),xsize(3))
    !
    real(mytype), dimension(xsize(1), xsize(2), xsize(3)) :: dpot1
    real(mytype), dimension(ysize(1), ysize(2), ysize(3)) :: pot2, dpot2
    real(mytype), dimension(zsize(1), zsize(2), zsize(3)) :: pot3, dpot3
    !
    call transpose_x_to_y(phi,pot2)
    call transpose_y_to_z(pot2,pot3)
    !
    call derxS (dpot1,  phi, di1, sx, ffxpS, fsxpS, fwxpS,      xsize(1), xsize(2), xsize(3), 1, zero)
    call deryS (dpot2, pot2, di2, sy, ffypS, fsypS, fwypS, ppy, ysize(1), ysize(2), ysize(3), 1, zero)
    call derzS (dpot3, pot3, di3, sz, ffzpS, fszpS, fwzpS,      zsize(1), zsize(2), zsize(3), 1, zero)
    !
    dphi(:,:,:,1)=dpot1
    !
    call transpose_y_to_x(dpot2,dpot1)
    !
    dphi(:,:,:,2)=dpot1
    !
    call transpose_z_to_y(dpot3,dpot2)
    call transpose_y_to_x(dpot2,dpot1)
    
    dphi(:,:,:,3)=dpot1
    !
  end function grad_vmesh
  !+-------------------------------------------------------------------+
  !| The end of the subroutine grad_vmesh.                             |
  !+-------------------------------------------------------------------+
  !
  !+-------------------------------------------------------------------+
  !| this subroutine is used to solve the poisson equation related to  |
  !| MHD.                                                              |
  !+-------------------------------------------------------------------+
  !| change record                                                     |
  !| -------------                                                     |
  !| 28-Oct-2022  | Created by J. Fang STFC Daresbury Laboratory       |
  !+-------------------------------------------------------------------+
  function solve_mhd_potential_poisson(ux1,uy1,uz1) result(jcurrent)

    use decomp_2d, only : zsize, ph1
    use decomp_2d_mpi, only: nrank
    use decomp_2d_poisson, only : poisson
    use var, only : nzmsize
    use param, only : ntime, nrhotime, npress,ilmn, ivarcoeff, zero, one 
    use navier,only : gradp

    implicit none

    !! inputs
    real(mytype),dimension(xsize(1), xsize(2), xsize(3)),intent(in) :: ux1, uy1, uz1
    real(mytype),dimension(xsize(1), xsize(2), xsize(3),1:3) :: jcurrent
    !
    !! local data
    real(mytype),dimension(xsize(1), xsize(2), xsize(3), 3) :: ucB
    real(mytype),dimension(ph1%zst(1):ph1%zen(1),ph1%zst(2):ph1%zen(2),nzmsize) :: rhs
    
    real(mytype),dimension(ph1%zst(1):ph1%zen(1),ph1%zst(2):ph1%zen(2),nzmsize) :: div3
    !
    integer :: i,j,k,nlock
    real(mytype) :: var1(3),var2(3)
    logical :: converged
    !
    nlock=1
    !
    do k = 1, xsize(3)
    do j = 1, xsize(2)
    do i = 1, xsize(1)
      !
      var1(1)=ux1(i,j,k)
      var1(2)=uy1(i,j,k)
      var1(3)=uz1(i,j,k)
      !
      ucB(i,j,k,:) =cross_product(var1,Bm(i,j,k,:))
      !
    enddo
    enddo
    enddo
    !
    rhs=divergence_scalar(ucB,nlock)
    !
    converged=.false.
    !
    do while(.not.converged)
      !
      call poisson(rhs)
      !
      CALL gradp(jcurrent(:,:,:,1),jcurrent(:,:,:,2),jcurrent(:,:,:,3),rhs)
      !
      converged=.true.
    enddo
    !
    do k = 1, xsize(3)
    do j = 1, xsize(2)
    do i = 1, xsize(1)
      !
      jcurrent(i,j,k,:)=-jcurrent(i,j,k,:)+ucB(i,j,k,:)
      !
    enddo
    enddo
    enddo
    !
  end function solve_mhd_potential_poisson
  !+-------------------------------------------------------------------+
  !| The end of the subroutine solve_mhd_potential_poisson.            |
  !+-------------------------------------------------------------------+
  !
  subroutine calculate_mhd_transeq_rhs(ux1,uy1,uz1)
    !
    !! INPUTS
    real(mytype),dimension(xsize(1),xsize(2),xsize(3)) :: ux1,uy1,uz1
    !
    call mhd_rhs_eq(dBm(:,:,:,:,1),Bm,Bmean,ux1,uy1,uz1)
    !
  end subroutine calculate_mhd_transeq_rhs
  !
  subroutine test_magnetic
    !
    use decomp_2d, only : zsize, ph1
    use var, only : nzmsize,itime,ilist,ifirst,ilast
    use navier, only : divergence
    use param, only : ntime,nrhotime

    ! FIXME
    ! The arrays below are often taken in the module var
    ! Here the names are similar but the arrays are local
    ! This is mesleading and it probably makes the MHD module incompatible with other modules such as IBM and LMN
    ! The compatibility of the MHD module with the other modules should be clarified
    !
    ! The subroutine mhd_init should print a warning or an error in case of compatibility issue using decomp_2d_warning or decomp_2d_abort
    !
    ! FIXME

    real(mytype),dimension(ph1%zst(1):ph1%zen(1),ph1%zst(2):ph1%zen(2),nzmsize) :: div3
    real(mytype), dimension(xsize(1), xsize(2), xsize(3)) :: ep1
    real(mytype), dimension(xsize(1), xsize(2), xsize(3), nrhotime) :: rho1
    real(mytype), dimension(xsize(1), xsize(2), xsize(3), ntime) :: drho1
    real(mytype), dimension(zsize(1), zsize(2), zsize(3))  :: divu3

    if ((mod(itime,ilist)==0 .or. itime == ifirst .or. itime == ilast)) then
      call divergence(div3,rho1,Bm(:,:,:,1),Bm(:,:,:,2),Bm(:,:,:,3),ep1,drho1,divu3,2)
    endif

  end subroutine test_magnetic
  !
  subroutine mhd_rhs_eq(dB,B,B0,ux1,uy1,uz1)

    use param
    use variables
    use decomp_2d
    use var, only : ta1,tb1,tc1,td1,te1,tf1,tg1,th1,ti1,di1,mu1,mu2,mu3
    use var, only : ux2,uy2,uz2,ta2,tb2,tc2,td2,te2,tf2,tg2,th2,ti2,tj2,di2
    use var, only : ux3,uy3,uz3,ta3,tb3,tc3,td3,te3,tf3,tg3,th3,ti3,di3
    use var, only : sgsx1,sgsy1,sgsz1
    use var, only : FTx, FTy, FTz, Fdiscx, Fdiscy, Fdiscz
    use ibm_param, only : ubcx,ubcy,ubcz
    use mpi

    implicit none

    !! INPUTS
    real(mytype),dimension(xsize(1),xsize(2),xsize(3)) :: ux1,uy1,uz1

    !! OUTPUTS
    real(mytype),dimension(xsize(1),xsize(2),xsize(3),1:3) :: B,B0,dB
    
    integer :: i,j,k,is
    !

    ! local 
    real(mytype) :: rrem
    real(mytype), save, allocatable, dimension(:,:,:) :: tx1,ty1,tz1,tx2,ty2,tz2, &
                                                         tx3,ty3,tz3,bx2,by2,bz2, &
                                                         bx3,by3,bz3,cx2,cy2,cz2, &
                                                         cx3,cy3,cz3
    real(mytype),dimension(xsize(1),xsize(2),xsize(3),1:3) :: Bsum
    logical,save :: firstcal=.true.

    if(firstcal) then
      !
      call alloc_x(tx1)
      tx1 = zero
      call alloc_x(ty1)
      ty1 = zero
      call alloc_x(tz1)
      tz1 = zero
  
      call alloc_y(tx2)
      tx2=zero
      call alloc_y(ty2)
      ty2=zero
      call alloc_y(tz2)
      tz2=zero
  
      call alloc_y(bx2)
      bx2=zero
      call alloc_y(by2)
      by2=zero
      call alloc_y(bz2)
      bz2=zero

      call alloc_z(tx3)
      tx3=zero
      call alloc_z(ty3)
      ty3=zero
      call alloc_z(tz3)
      tz3=zero
      !
      call alloc_z(bx3)
      bx3=zero
      call alloc_z(by3)
      by3=zero
      call alloc_z(bz3)
      bz3=zero
      !
      call alloc_y(cx2)
      bx2=zero
      call alloc_y(cy2)
      by2=zero
      call alloc_y(cz2)
      bz2=zero
      !
      call alloc_z(cx3)
      bx3=zero
      call alloc_z(cy3)
      by3=zero
      call alloc_z(cz3)
      bz3=zero
      !
      firstcal=.false.
    endif

    rrem=1._mytype/Rem

    Bsum=B+B0

    !SKEW SYMMETRIC FORM

    !WORK X-PENCILS
    ta1(:,:,:) = ux1(:,:,:) * Bsum(:,:,:,1) - Bsum(:,:,:,1) * ux1(:,:,:) 
    tb1(:,:,:) = ux1(:,:,:) * Bsum(:,:,:,2) - Bsum(:,:,:,1) * uy1(:,:,:)
    tc1(:,:,:) = ux1(:,:,:) * Bsum(:,:,:,3) - Bsum(:,:,:,1) * uz1(:,:,:)
    
    call derx (td1,ta1,di1,sx,ffxp,fsxp,fwxp,xsize(1),xsize(2),xsize(3),1,ubcx*ubcx)
    call derx (te1,tb1,di1,sx,ffx,fsx,fwx,xsize(1),xsize(2),xsize(3),0,ubcx*ubcy)
    call derx (tf1,tc1,di1,sx,ffx,fsx,fwx,xsize(1),xsize(2),xsize(3),0,ubcx*ubcz)

    call derx (ta1,ux1,di1,sx,ffx,fsx,fwx,xsize(1),xsize(2),xsize(3),0,ubcx)
    call derx (tb1,uy1,di1,sx,ffxp,fsxp,fwxp,xsize(1),xsize(2),xsize(3),1,ubcy)
    call derx (tc1,uz1,di1,sx,ffxp,fsxp,fwxp,xsize(1),xsize(2),xsize(3),1,ubcz)
    !
    call derx (tx1,Bsum(:,:,:,1),di1,sx,ffx,fsx,fwx,xsize(1),xsize(2),xsize(3),0,ubcx)
    call derx (ty1,Bsum(:,:,:,2),di1,sx,ffxp,fsxp,fwxp,xsize(1),xsize(2),xsize(3),1,ubcy)
    call derx (tz1,Bsum(:,:,:,3),di1,sx,ffxp,fsxp,fwxp,xsize(1),xsize(2),xsize(3),1,ubcz)


    ! Convective terms of x-pencil are stored in tg1,th1,ti1
    
    tg1(:,:,:) = td1(:,:,:)  + ux1(:,:,:) * tx1(:,:,:) - Bsum(:,:,:,1) * ta1(:,:,:)
    th1(:,:,:) = te1(:,:,:)  + ux1(:,:,:) * ty1(:,:,:) - Bsum(:,:,:,1) * tb1(:,:,:)
    ti1(:,:,:) = tf1(:,:,:)  + ux1(:,:,:) * tz1(:,:,:) - Bsum(:,:,:,1) * tc1(:,:,:)

    ! TODO: save the x-convective terms already in dux1, duy1, duz1

    call transpose_x_to_y(ux1,ux2)
    call transpose_x_to_y(uy1,uy2)
    call transpose_x_to_y(uz1,uz2)
    
    call transpose_x_to_y(Bsum(:,:,:,1),bx2)
    call transpose_x_to_y(Bsum(:,:,:,2),by2)
    call transpose_x_to_y(Bsum(:,:,:,3),bz2)

    call transpose_x_to_y(B(:,:,:,1),cx2)
    call transpose_x_to_y(B(:,:,:,2),cy2)
    call transpose_x_to_y(B(:,:,:,3),cz2)


    !WORK Y-PENCILS
    td2(:,:,:) =  uy2(:,:,:)*bx2(:,:,:) - by2(:,:,:)*ux2(:,:,:) 
    te2(:,:,:) =  uy2(:,:,:)*by2(:,:,:) - by2(:,:,:)*uy2(:,:,:) 
    tf2(:,:,:) =  uy2(:,:,:)*bz2(:,:,:) - by2(:,:,:)*uz2(:,:,:) 

    call dery (tg2,td2,di2,sy,ffy,  fsy, fwy,ppy,ysize(1),ysize(2),ysize(3),0,ubcx*ubcy)
    call dery (th2,te2,di2,sy,ffyp,fsyp,fwyp,ppy,ysize(1),ysize(2),ysize(3),1,ubcy*ubcy)
    call dery (ti2,tf2,di2,sy,ffy,  fsy, fwy,ppy,ysize(1),ysize(2),ysize(3),0,ubcz*ubcy)

    call dery (td2,ux2,di2,sy,ffyp,fsyp,fwyp,ppy,ysize(1),ysize(2),ysize(3),1,ubcx)
    call dery (te2,uy2,di2,sy,ffy,  fsy ,fwy,ppy,ysize(1),ysize(2),ysize(3),0,ubcy)
    call dery (tf2,uz2,di2,sy,ffyp,fsyp,fwyp,ppy,ysize(1),ysize(2),ysize(3),1,ubcz)

    call dery (tx2,bx2,di2,sy,ffyp,fsyp,fwyp,ppy,ysize(1),ysize(2),ysize(3),1,ubcx)
    call dery (ty2,by2,di2,sy,ffy,  fsy ,fwy,ppy,ysize(1),ysize(2),ysize(3),0,ubcy)
    call dery (tz2,bz2,di2,sy,ffyp,fsyp,fwyp,ppy,ysize(1),ysize(2),ysize(3),1,ubcz)


    ! Convective terms of y-pencil in tg2,th2,ti2

    tg2(:,:,:) = tg2(:,:,:)  + uy2(:,:,:) * tx2(:,:,:) - by2(:,:,:) * td2(:,:,:)
    th2(:,:,:) = th2(:,:,:)  + uy2(:,:,:) * ty2(:,:,:) - by2(:,:,:) * te2(:,:,:)
    ti2(:,:,:) = ti2(:,:,:)  + uy2(:,:,:) * tz2(:,:,:) - by2(:,:,:) * tf2(:,:,:)

    call transpose_y_to_z(ux2,ux3)
    call transpose_y_to_z(uy2,uy3)
    call transpose_y_to_z(uz2,uz3)

    call transpose_y_to_z(bx2,bx3)
    call transpose_y_to_z(by2,by3)
    call transpose_y_to_z(bz2,bz3)

    call transpose_y_to_z(cx2,cx3)
    call transpose_y_to_z(cy2,cy3)
    call transpose_y_to_z(cz2,cz3)

    !WORK Z-PENCILS

    td3(:,:,:) =  uz3(:,:,:)*bx3(:,:,:) - bz3(:,:,:)*ux3(:,:,:)
    te3(:,:,:) =  uz3(:,:,:)*by3(:,:,:) - bz3(:,:,:)*uy3(:,:,:)
    tf3(:,:,:) =  uz3(:,:,:)*bz3(:,:,:) - bz3(:,:,:)*uz3(:,:,:)


    call derz (tg3,td3,di3,sz,ffz,fsz,fwz,zsize(1),zsize(2),zsize(3),0,ubcx*ubcz)
    call derz (th3,te3,di3,sz,ffz,fsz,fwz,zsize(1),zsize(2),zsize(3),0,ubcy*ubcz)
    call derz (ti3,tf3,di3,sz,ffzp,fszp,fwzp,zsize(1),zsize(2),zsize(3),1,ubcz*ubcz)

    call derz (td3,ux3,di3,sz,ffzp,fszp,fwzp,zsize(1),zsize(2),zsize(3),1,ubcx)
    call derz (te3,uy3,di3,sz,ffzp,fszp,fwzp,zsize(1),zsize(2),zsize(3),1,ubcy)
    call derz (tf3,uz3,di3,sz,ffz,fsz,fwz,zsize(1),zsize(2),zsize(3),0,ubcz)

    call derz (tx3,bx3,di3,sz,ffzp,fszp,fwzp,zsize(1),zsize(2),zsize(3),1,ubcx)
    call derz (ty3,by3,di3,sz,ffzp,fszp,fwzp,zsize(1),zsize(2),zsize(3),1,ubcy)
    call derz (tz3,bz3,di3,sz,ffz,fsz,fwz,zsize(1),zsize(2),zsize(3),0,ubcz)

    ! Convective terms of z-pencil in ta3,tb3,tc3

    ta3(:,:,:) = tg3(:,:,:) + uz3(:,:,:) * tx3(:,:,:) - bz3(:,:,:) * td3(:,:,:)
    tb3(:,:,:) = th3(:,:,:) + uz3(:,:,:) * ty3(:,:,:) - bz3(:,:,:) * te3(:,:,:)
    tc3(:,:,:) = ti3(:,:,:) + uz3(:,:,:) * tz3(:,:,:) - bz3(:,:,:) * tf3(:,:,:)


    ! Convective terms of z-pencil are in ta3 -> td3, tb3 -> te3, tc3 -> tf3
    td3(:,:,:) = ta3(:,:,:)
    te3(:,:,:) = tb3(:,:,:)
    tf3(:,:,:) = tc3(:,:,:)

    !DIFFUSIVE TERMS IN Z
    call derzz (ta3,cx3,di3,sz,sfzp,sszp,swzp,zsize(1),zsize(2),zsize(3),1,ubcx)
    call derzz (tb3,cy3,di3,sz,sfzp,sszp,swzp,zsize(1),zsize(2),zsize(3),1,ubcy)
    call derzz (tc3,cz3,di3,sz,sfz ,ssz ,swz ,zsize(1),zsize(2),zsize(3),0,ubcz)


    ! Add convective and diffusive terms of z-pencil (half for skew-symmetric)

    td3(:,:,:) = rrem*ta3(:,:,:) - half * td3(:,:,:)
    te3(:,:,:) = rrem*tb3(:,:,:) - half * te3(:,:,:)
    tf3(:,:,:) = rrem*tc3(:,:,:) - half * tf3(:,:,:)


    !WORK Y-PENCILS
    call transpose_z_to_y(td3,td2)
    call transpose_z_to_y(te3,te2)
    call transpose_z_to_y(tf3,tf2)

    ! Convective terms of y-pencil (tg2,th2,ti2) and sum of convective and diffusive terms of z-pencil (td2,te2,tf2) are now in tg2, th2, ti2 (half for skew-symmetric)
    tg2(:,:,:) = td2(:,:,:) - half * tg2(:,:,:)
    th2(:,:,:) = te2(:,:,:) - half * th2(:,:,:)
    ti2(:,:,:) = tf2(:,:,:) - half * ti2(:,:,:)


    !DIFFUSIVE TERMS IN Y
    !-->for ux
    call deryy (td2,cx2,di2,sy,sfyp,ssyp,swyp,ysize(1),ysize(2),ysize(3),1,ubcx)
    if (istret.ne.0) then
       call dery (te2,bx2,di2,sy,ffyp,fsyp,fwyp,ppy,ysize(1),ysize(2),ysize(3),1,ubcx)
       do k = 1,ysize(3)
          do j = 1,ysize(2)
             do i = 1,ysize(1)
                td2(i,j,k) = td2(i,j,k)*pp2y(j)-pp4y(j)*te2(i,j,k)
             enddo
          enddo
       enddo
    endif

    !-->for uy
    call deryy (te2,cy2,di2,sy,sfy,ssy,swy,ysize(1),ysize(2),ysize(3),0,ubcy)
    if (istret.ne.0) then
       call dery (tf2,by2,di2,sy,ffy,fsy,fwy,ppy,ysize(1),ysize(2),ysize(3),0,ubcy)
       do k = 1,ysize(3)
          do j = 1,ysize(2)
             do i = 1,ysize(1)
                te2(i,j,k) = te2(i,j,k)*pp2y(j)-pp4y(j)*tf2(i,j,k)
             enddo
          enddo
       enddo
    endif

    !-->for uz
    call deryy (tf2,cz2,di2,sy,sfyp,ssyp,swyp,ysize(1),ysize(2),ysize(3),1,ubcz)
    if (istret.ne.0) then
       call dery (tj2,bz2,di2,sy,ffyp,fsyp,fwyp,ppy,ysize(1),ysize(2),ysize(3),1,ubcz)
       do k = 1,ysize(3)
          do j = 1,ysize(2)
             do i = 1,ysize(1)
                tf2(i,j,k) = tf2(i,j,k)*pp2y(j)-pp4y(j)*tj2(i,j,k)
             enddo
          enddo
       enddo
    endif

    ! Add diffusive terms of y-pencil to convective and diffusive terms of y- and z-pencil
    ta2(:,:,:) = rrem*td2(:,:,:) + tg2(:,:,:)
    tb2(:,:,:) = rrem*te2(:,:,:) + th2(:,:,:)
    tc2(:,:,:) = rrem*tf2(:,:,:) + ti2(:,:,:)

    !WORK X-PENCILS
    call transpose_y_to_x(ta2,ta1)
    call transpose_y_to_x(tb2,tb1)
    call transpose_y_to_x(tc2,tc1) !diff+conv. terms

    !DIFFUSIVE TERMS IN X
    call derxx (td1,B(:,:,:,1),di1,sx,sfx ,ssx ,swx ,xsize(1),xsize(2),xsize(3),0,ubcx)
    call derxx (te1,B(:,:,:,2),di1,sx,sfxp,ssxp,swxp,xsize(1),xsize(2),xsize(3),1,ubcy)
    call derxx (tf1,B(:,:,:,3),di1,sx,sfxp,ssxp,swxp,xsize(1),xsize(2),xsize(3),1,ubcz)

    td1(:,:,:) = rrem * td1(:,:,:)
    te1(:,:,:) = rrem * te1(:,:,:)
    tf1(:,:,:) = rrem * tf1(:,:,:)

    !FINAL SUM: DIFF TERMS + CONV TERMS
    dB(:,:,:,1) = ta1(:,:,:) - half*tg1(:,:,:)  + td1(:,:,:)
    dB(:,:,:,2) = tb1(:,:,:) - half*th1(:,:,:)  + te1(:,:,:)
    dB(:,:,:,3) = tc1(:,:,:) - half*ti1(:,:,:)  + tf1(:,:,:)

    return

  end subroutine mhd_rhs_eq
  !
  subroutine solve_poisson_mhd
    !
    use decomp_2d, only : zsize, ph1
    use decomp_2d_mpi, only : nrank
    use decomp_2d_poisson, only : poisson
    use var, only : nzmsize
    use param, only : ntime, nrhotime, npress,ilmn, ivarcoeff, zero, one 
    use navier,only : gradp

    real(mytype),dimension(ph1%zst(1):ph1%zen(1),ph1%zst(2):ph1%zen(2),nzmsize) :: phib

    real(mytype),dimension(xsize(1),xsize(2),xsize(3),1:3) :: dphib

    integer :: i,j,k,nlock,poissiter
    !
    nlock=1 !! Corresponds to computing div(u*)
    !
    do poissiter = 1, 1
      phib=divergence_scalar(Bm,nlock) !todo: this will have incorrect BCs?
      call poisson(phib)
      CALL gradp(dphib(:,:,:,1),dphib(:,:,:,2),dphib(:,:,:,3),phib)
      Bm=Bm-dphib
    enddo
    !
  end subroutine solve_poisson_mhd
  !
  !!############################################################################
  !subroutine DIVERGENCE for a generic vector field
  !Calculation of div 
  ! input :  vec (on velocity mesh)
  ! output : pp3 (on pressure mesh)
  !written by SL 2018
  !############################################################################
  function divergence_scalar(vec,nlock) result(pp3)

    USE param
    USE decomp_2d
    USE variables
    USE var, ONLY: ta1, tb1, tc1, pp1, pgy1, pgz1, di1, &
         duxdxp2, uyp2, uzp2, duydypi2, upi2, ta2, dipp2, &
         duxydxyp3, uzp3, po3, dipp3, nxmsize, nymsize, nzmsize

    implicit none

    !  TYPE(DECOMP_INFO) :: ph1,ph3,ph4

    !X PENCILS NX NY NZ  -->NXM NY NZ
    real(mytype),dimension(xsize(1),xsize(2),xsize(3),3),intent(in) :: vec
    !
    real(mytype),dimension(ph1%zst(1):ph1%zen(1),ph1%zst(2):ph1%zen(2),nzmsize) :: pp3

    integer :: nvect3,i,j,k,nlock
    integer :: code
    real(mytype) :: tmax,tmoy,tmax1,tmoy1

    nvect3=(ph1%zen(1)-ph1%zst(1)+1)*(ph1%zen(2)-ph1%zst(2)+1)*nzmsize

    ta1(:,:,:) = vec(:,:,:,1)
    tb1(:,:,:) = vec(:,:,:,2)
    tc1(:,:,:) = vec(:,:,:,3)

    !WORK X-PENCILS

    call derxvp(pp1,ta1,di1,sx,cfx6,csx6,cwx6,xsize(1),nxmsize,xsize(2),xsize(3),0)

    call interxvp(pgy1,tb1,di1,sx,cifxp6,cisxp6,ciwxp6,xsize(1),nxmsize,xsize(2),xsize(3),1)
    call interxvp(pgz1,tc1,di1,sx,cifxp6,cisxp6,ciwxp6,xsize(1),nxmsize,xsize(2),xsize(3),1)

    call transpose_x_to_y(pp1,duxdxp2,ph4)!->NXM NY NZ
    call transpose_x_to_y(pgy1,uyp2,ph4)
    call transpose_x_to_y(pgz1,uzp2,ph4)

    !WORK Y-PENCILS
    call interyvp(upi2,duxdxp2,dipp2,sy,cifyp6,cisyp6,ciwyp6,(ph1%yen(1)-ph1%yst(1)+1),ysize(2),nymsize,ysize(3),1)
    call deryvp(duydypi2,uyp2,dipp2,sy,cfy6,csy6,cwy6,ppyi,(ph1%yen(1)-ph1%yst(1)+1),ysize(2),nymsize,ysize(3),0)
    !! Compute sum dudx + dvdy
    duydypi2(:,:,:) = duydypi2(:,:,:) + upi2(:,:,:)

    call interyvp(upi2,uzp2,dipp2,sy,cifyp6,cisyp6,ciwyp6,(ph1%yen(1)-ph1%yst(1)+1),ysize(2),nymsize,ysize(3),1)

    call transpose_y_to_z(duydypi2,duxydxyp3,ph3)!->NXM NYM NZ
    call transpose_y_to_z(upi2,uzp3,ph3)

    !WORK Z-PENCILS
    call interzvp(pp3,duxydxyp3,dipp3,sz,cifzp6,ciszp6,ciwzp6,(ph1%zen(1)-ph1%zst(1)+1),&
         (ph1%zen(2)-ph1%zst(2)+1),zsize(3),nzmsize,1)
    call derzvp(po3,uzp3,dipp3,sz,cfz6,csz6,cwz6,(ph1%zen(1)-ph1%zst(1)+1),&
         (ph1%zen(2)-ph1%zst(2)+1),zsize(3),nzmsize,0)

    !! Compute sum dudx + dvdy + dwdz
    pp3(:,:,:) = pp3(:,:,:) + po3(:,:,:)

    if (nlock==2) then
       pp3(:,:,:)=pp3(:,:,:)-pp3(ph1%zst(1),ph1%zst(2),nzmsize)
    endif

    tmax=-1609._mytype
    tmoy=zero
    do k=1,nzmsize
       do j=ph1%zst(2),ph1%zen(2)
          do i=ph1%zst(1),ph1%zen(1)
             if (pp3(i,j,k).gt.tmax) tmax=pp3(i,j,k)
             tmoy=tmoy+abs(pp3(i,j,k))
          enddo
       enddo
    enddo
    tmoy=tmoy/nvect3

    tmax1 = pmax(tmax)
    tmoy1 = psum(tmoy)

    if ((nrank == 0) .and. (nlock > 0).and.(mod(itime, ilist) == 0 .or. itime == ifirst .or. itime==ilast)) then
       if (nlock == 2) then
          write(*,*) 'DIV B  max mean=',real(tmax1,mytype),real(tmoy1/real(nproc),mytype)
       else
          write(*,*) 'DIV B* max mean=',real(tmax1,mytype),real(tmoy1/real(nproc),mytype)
       endif
    endif

    return
    !
  end function divergence_scalar
  !
end module mhd
